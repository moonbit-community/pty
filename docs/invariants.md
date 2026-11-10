# Invariants — do not regress

Hard-won conclusions from debugging, and decision records with their
rationale. Nothing here is pending work; it is documented so it doesn't get
"fixed" back into a bug.

## Both platforms

- The cancellation grace period is 5000ms on both platforms (decided
  2026-08-14): it matches the ~5s Windows itself grants on CTRL_CLOSE_EVENT,
  and unix follows for cross-platform consistency. The value lives in
  `GRACE_PERIOD_MS` (`pty.mbt`, the library's cancellation cleanup) and
  `GRACE_MS` (`sidecar/sidecar.c`, used when the parent goes away without a
  cleanup); keep the two in sync by hand.
- In the cancellation cleanup the exit waiter is a spawned task
  (`wait_with` in `pty.mbt`), never the main task of a `with_task_group`.
  Reason: moonbitlang/async's `with_task_group` aborts the process
  (`result.unwrap()` on a `Done` group with no result, `task_group.mbt:270` as
  of 0.22.4) when its main task is cancelled directly by the runtime, which
  `EventLoop::cleanup` does to every fd/pid waiter after a fatal error in the
  host event loop. With the waiter as a child task the group fails with
  `@async.WaitedTaskAlreadyCancelled` instead, and `Task::wait` propagates that error.
  `pty_wbtest.mbt` guards this by cancelling the waiter through the `on_waiter`
  hook; the end-to-end reproduction (a fake `ExternalEventLoop` whose `poll`
  raises while the cleanup group is alive) is not in the repo. Do not fold the
  waiter back into the main task.
- The cleanup that runs after cancellation is entered through
  `@async.handle_cancellation` + `@async.protect_from_cancel`, never a `catch`
  arm (decided 2026-09-22, async 0.22). In 0.22 `catch` stopped observing
  cancellation — `Cancelled` is no longer an error, the signal is a runtime
  primitive — so the `error if @async.is_being_cancelled()` form the library
  used at 0.21 became dead code: closing the terminal, the grace period, and
  the SIGKILL silently stopped running while the code still looked
  responsible. The 0.22 form completes with the child's exit status rather
  than re-raising, like 0.22's own `@async/process.spawn`; the only public way
  to re-raise (`@async.pause`) is an unrelated scheduling yield. The
  SIGHUP-ignoring child test in `pty_unix_test.mbt` is the guard — it fails if
  the cleanup does not run.

## The sidecar (decided 2026-11-10)

- Every target reaches the pty through the sidecar process
  (`sidecar/sidecar.c`, MoonBit side in `internal/sidecar`), native
  included. moon has no per-target imports, and the old native path needed
  `moonbitlang/async/raw_fd`, which is native-only, so a package using it
  could not declare wasm at all; moonrun's host imports are a fixed set with
  no pty support. `moonbit-community/tty` made the same move. Do not bring
  back a direct FFI path without first solving that import problem.
- Terminal output is the sidecar's raw stdout, not frames: reads are plain
  pipe reads with the pipe's own backpressure, and waiting for the exit
  never depends on someone reading output. Commands are framed on stdin,
  events framed on stderr.
- Events are read by whichever task needs one (`Sidecar::pump_until`), never
  by a background task. The cancellation cleanup must still be able to see
  the child's EXIT while every other task of the group is being cancelled,
  and a background reader would be cancelled with them.
- Writes are flow controlled with WROTE acknowledgements (64 KiB in
  flight), so writing to a child that does not read blocks, as it does on
  a real pty, and the sidecar keeps reading commands: a HANGUP or KILL is
  never stuck behind queued input.
- Resize replies are matched by sequence number, and a resize cancelled
  while waiting drops out of the waiting set, so its late reply is never
  taken by the next resize.
- Errors from the event stream are kept in `Sidecar::failure` from a
  `catch`, not set from an `errdefer`: since async 0.22 `errdefer` also runs
  on cancellation, and a merely cancelled read must not mark the stream
  dead (it made every cancellation path report a lost sidecar).
- The Unix sidecar uses `select`, not `poll`: macOS `poll()` does not
  support character devices such as the pty primary.
- The sidecar ignores SIGHUP, SIGINT and SIGQUIT and lives exactly as long
  as its command pipe; terminal-generated signals aimed at the parent's
  process group must not take it down while the parent survives them. The
  child resets every disposition before `exec`.
- When the output pipe is gone (the parent closed it, as the cancellation
  cleanup does first), the sidecar keeps draining the terminal into the
  void, so neither a child nor ConPTY's teardown can block on a full pipe.
- The embedded sidecar is written once per content hash to the user's cache
  directory and reused (`cached_path` in `internal/sidecar/locate.mbt`):
  macOS checks every new executable on its first launch, about 300 ms,
  which a fresh copy per spawn paid every time. The shared temporary
  directory is only used as a per-spawn fallback, in a private `mkdtemp`
  directory, because a predictable path there could be planted by another
  user.

## Unix

- `execve` retries ETXTBSY (bounded: 20 × 50ms, plus a final attempt) in
  `execve_ignore_etxtbsy` (`sidecar/sidecar.c`). Decided 2026-08-14 after the
  write-a-script-then-spawn test failed once on GitHub's ubuntu runner
  (run 31773488278) and the failure could not be reproduced anywhere else:
  100× `moon test` plus ~1000× write+spawn stress under `taskset -c 0,1`
  with background load on real Linux hardware all came back clean, and
  source reading rules out any in-process window (async's Linux backend is
  epoll + thread pool, and `File::close` → `fd_util.close` is a synchronous
  bare close(2), sequenced strictly before our fork).

  Prior art is split by layer, not by project. Go's os/exec does NOT
  auto-retry (golang/go#22315, still open: a general spawn library cannot
  tell a transient pre-exec-window fd from a file legitimately held open for
  writing), and neither do Rust (rust-lang/rust#114554) nor .NET
  (dotnet/runtime#58964). But cmd/go — the caller that KNOWS it just wrote
  the binary — retries in an unbounded no-backoff loop (golang/go#62221,
  landed 1.22, backported 1.21): "we know that they should resolve quickly
  (the ETXTBSY error will resolve as soon as the subprocess holding the
  descriptor open reaches its 'exec' call), we retry them in a loop." This
  library sits between the two: pty users commonly write-a-script-then-spawn,
  and the async runtime itself may manufacture the window (so callers can't
  avoid it with fd discipline) — hence the bounded retry. Win32 has no
  ETXTBSY, so platform symmetry is unaffected.

  If CI ever reports ETXTBSY again *through* the retry, the file is being
  held open persistently by something on the runner — investigate that,
  don't just raise the bound.

## Windows ConPTY

- The sidecar's `spawn_child` must set `STARTF_USESTDHANDLES` with null std
  handles. Without it, `CreateProcessW` duplicates the parent's redirected
  std handles into the child and its output bypasses the ConPTY.
- The ConPTY output pipe only reaches EOF after `ClosePseudoConsole`, so
  the sidecar's wait thread closes the HPCON as soon as the child exits
  (after sending EXIT, so the exit is reported even if the close blocks).
- `ClosePseudoConsole` must never block on a full output pipe (decided
  2026-10-11, reshaped 2026-11-10). Before Windows 11 24H2 (build 26100) it
  waits for the pseudoconsole to exit, and the pseudoconsole blocks writing
  to a full output pipe; Microsoft's documentation requires closing the
  output pipe first or reading it until the call returns. The sidecar's
  output thread always keeps reading (discarding once the parent closed its
  end), and every `ClosePseudoConsole` runs off the command thread, so a
  HANGUP or KILL is still served meanwhile. From 24H2 on the call returns
  immediately, so a runner that new cannot catch a regression: the
  `windows-2022` CI job exists for this, and the flooding-child test in
  `pty_win32_test.mbt` fails there by running into the job's
  `timeout-minutes`.
- `ClosePseudoConsole` must never run twice on the same HPCON (heap
  corruption, 0xC0000374) — the sidecar guards it with `hpc_closed`
  (`InterlockedExchange`) and serializes it against `ResizePseudoConsole`.
- `CreateProcessW` mutates the command-line buffer in place; always pass a
  fresh heap copy, never a string literal (they live in read-only memory).
- ConPTY is a screen renderer, not a byte pipe: its output always carries VT
  sequences (initial clear-screen + repaint). Never print raw pty output in
  test assertions or failure diffs — `escape()` it or strip the sequences —
  or a failing test replays them into the developer's terminal.
- The resolved executable goes to `CreateProcessW`'s `lpApplicationName`;
  the command line's argv[0] stays the caller's `file` verbatim. Passing
  NULL `lpApplicationName` regresses to the native search (parent's cwd,
  no `cwd` participation) and reintroduces the resolver's reason to exist.
- Env blocks are merged case-insensitively before serialization (uppercase-
  keyed map, inherited key casing preserved, one entry per variable).
  `String::to_upper` is Unicode case folding while Windows compares keys
  ordinal-ignore-case — a known, benign divergence for exotic keys.
- The win32 spawn failure branches are executed by the error-path tests in
  `pty_win32_test.mbt`; on failure the sidecar reports SPAWN_FAILED and
  exits, so its handles go with the process. `CreateProcessW` on a text file
  named `foo.exe` returns ERROR_EXE_MACHINE_TYPE_MISMATCH (216) on Windows 11,
  not the classic ERROR_BAD_EXE_FORMAT (193) — the test accepts both.
