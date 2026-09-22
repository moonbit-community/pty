# Invariants — do not regress

Hard-won conclusions from debugging, and decision records with their
rationale. Nothing here is pending work; it is documented so it doesn't get
"fixed" back into a bug.

## Both platforms

- The cancellation grace period is 5000ms on both platforms (decided
  2026-08-14): it matches the ~5s Windows itself grants on CTRL_CLOSE_EVENT,
  and unix follows for cross-platform consistency. The value lives in both
  `pty_unix.mbt` and `pty_win32.mbt`; `#cfg` means the inactive platform is
  not type-checked, so a change to one side cannot be caught by the compiler
  on the other — keep them in sync by hand.
- In the cancellation cleanup the `wait_pid` waiter is a spawned task
  (`wait_pid_with` in `pty.mbt`), never the main task of a `with_task_group`.
  Reason: moonbitlang/async's `with_task_group` aborts the process
  (`result.unwrap()` on a `Done` group with no result, `task_group.mbt:270` as
  of 0.22.1) when its main task is cancelled directly by the runtime, which
  `EventLoop::cleanup` does to every fd/pid waiter after a fatal error in the
  host event loop. With the waiter as a child task the group fails with
  `@async.TaskCancelled` instead, and `Task::wait` propagates that error.
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

## Unix

- `execve` retries ETXTBSY (bounded: 20 × 50ms, plus a final attempt) in
  `moonbit_pty_unix_execve_ignore_etxtbsy`. Decided 2026-08-14 after the
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

- `moonbit_pty_win32_spawn` must set `STARTF_USESTDHANDLES` with null std
  handles. Without it, `CreateProcessW` duplicates the parent's redirected
  std handles into the child and its output bypasses the ConPTY.
- The ConPTY output pipe only reaches EOF after `ClosePseudoConsole`, so
  the wait task must close the HPCON as soon as `wait_pid` returns.
- `ClosePseudoConsole` must never run twice on the same HPCON (heap
  corruption, 0xC0000374) — closing is guarded by `hpc : Ref[PseudoConsole?]`.
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
- The win32 spawn failure branches were audited 2026-08-14 (no double-closes;
  the three direct `hpc.close()` sites before the `Ref(Some(...))` wrap are
  mutually exclusive and each followed by `raise`) and are now executed by the
  error-path tests in `pty_win32_test.mbt`. `CreateProcessW` on a text file
  named `foo.exe` returns ERROR_EXE_MACHINE_TYPE_MISMATCH (216) on Windows 11,
  not the classic ERROR_BAD_EXE_FORMAT (193) — the test accepts both.
