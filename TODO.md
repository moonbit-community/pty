# TODO

## Unix (needs a unix machine to fix & verify)

1. **`cwd` is silently ignored.** The `pty_spawn` extern in `pty_unix.mbt`
   passes 6 arguments but `moonbit_pty_spawn` in `pty_unix.c` only takes 5;
   the child never `chdir`s. Add the `cwd` parameter on the C side and
   `chdir` in the child before `execve` (report failure through `efd`).
2. **Map EIO on the primary to EOF unconditionally.** `_direct_read`
   currently only maps EIO to 0 when the pty was closed explicitly. On
   Linux, reading the primary after the child exits returns EIO (macOS
   returns 0), so a naturally-exiting child raises an error instead of
   EOF — the "@pty.spawn" test fails on Linux because of this.
3. Replace the `__USE_XOPEN_EXTENDED` / `__USE_GNU` defines in the middle
   of `pty_unix.c`'s includes with `#define _GNU_SOURCE` at the very top.
4. `moonbit_pty_is_executable` returns 0 with a stale `errno` when the path
   exists but is not a regular file; set `errno` explicitly so
   `resolve_path` reports a meaningful error.
5. Silence the unused-variable warning in `moonbit_pty__fork_fail`.
6. **Remove `pub fn Pty::close` on unix.** Manual close is no longer part
   of the API (already removed on Windows: the pseudoconsole is closed by
   the wait task when the child exits, streams are closed via
   `group.add_defer`). Also unify the cancellation grace period
   (win32 uses 5000ms, unix uses 1000ms).
7. Decide whether `execve` needs a retry for transient failures
   (e.g. `ETXTBSY`). main's 8c91701 added spawn retries for the old
   helper-based architecture and was dropped in the rewrite rebase.

## Docs

8. Rewrite `README.md`: it still describes the old `openpty()` + helper
   self-spawn architecture, which the rewrite replaced with fork+execve
   on unix and ConPTY on Windows.

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
