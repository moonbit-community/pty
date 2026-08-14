# TODO

## Unix

1. **ETXTBSY on Linux CI — merge blocker; reproduce on a Linux box, then
   decide the fix there.** PR #18's ubuntu job fails (run 31773488278):
   `@pty.spawn resolves a relative file against cwd` gets
   `OSError("@pty.spawn: Text file busy")` — the test writes `echo.sh` via
   `@async/fs.write_file` and spawns it immediately. macOS never hits this.

   What we know so far (2026-08-14):
   - The candidate loop treats ETXTBSY as fatal (only EACCES/ENOENT/ENOTDIR
     continue); main's 8c91701 had spawn retries and the rewrite dropped them.
   - Mechanism status (updated 2026-08-14, later): BOTH in-process theories
     are dead. moonbitlang/async's Linux backend is epoll + worker thread
     pool (no io_uring), and `File::close` → `IoHandle::close` →
     `fd_util.close` is a synchronous bare close(2) on the calling thread
     (fd_util.mbt:58) — the write fd is physically closed before
     `write_file` returns, sequenced strictly before our fork. From source,
     no in-process window exists. The execve-time writer is therefore
     probably OUTSIDE our process (something on the runner opening fresh
     files O_RDWR?), or a mechanism not yet identified.
   - Frequency: exactly ONE occurrence so far (run 31773488278); the four
     earlier red runs were unrelated win32 dev failures. 100 local
     `moon test` runs on a fast Linux box did not reproduce — each run is a
     single write+spawn trial, so that bounds little.
   - Next probes: (i) a scratch stress test looping
     write_file → spawn → wait ~1000×/run (3 orders of magnitude more
     trials), under `taskset -c 0,1` plus background load to mimic the
     2-core runner; (ii) make CI self-diagnosing — temporary commit where
     the test catches ETXTBSY, immediately retries (an instant success
     proves transience and measures the window) AND scans /proc/*/fd via
     readlink for the holder, failing with both findings; optionally a
     workflow_dispatch stress job on ubuntu-latest for real-environment
     trials.
   - Prior art is split by layer, not by project. Go's os/exec does NOT
     auto-retry (golang/go#22315, still open: a general spawn library cannot
     tell a transient pre-exec-window fd from a file legitimately held open
     for writing). But cmd/go — the caller that KNOWS it just wrote the
     binary — retries in an unbounded no-backoff loop (golang/go#62221,
     landed 1.22, backported 1.21): "we know that they should resolve
     quickly (the ETXTBSY error will resolve as soon as the subprocess
     holding the descriptor open reaches its 'exec' call), we retry them in
     a loop." Rust (#114554) and .NET (dotnet/runtime#58964) also have no
     library-level retry.
   - Options: (a) os/exec-style — keep single execve, retry in the test
     that writes-then-spawns; (b) cmd/go-style but bounded, in the C
     candidate loop (e.g. 20 × 50ms nanosleep on ETXTBSY). Claude leans
     (b): pty users commonly write-a-script-then-spawn, the async runtime
     itself may manufacture the window (so callers can't avoid it with fd
     discipline), and win32 has no ETXTBSY so symmetry is unaffected.
     Decide after reproducing.

## Windows ConPTY — do not regress

Hard-won conclusions from debugging; keep these invariants:

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
- The cancellation grace period is 5000ms on both platforms (decided
  2026-08-14): it matches the ~5s Windows itself grants on CTRL_CLOSE_EVENT,
  and unix follows for cross-platform consistency. The value lives in both
  `pty_unix.mbt` and `pty_win32.mbt`; `#cfg` means the inactive platform is
  not type-checked, so a change to one side cannot be caught by the compiler
  on the other — keep them in sync by hand.
