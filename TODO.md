# TODO

## Unix

1. Decide whether `execve` needs a retry for transient failures
   (e.g. `ETXTBSY`). main's 8c91701 added spawn retries for the old
   helper-based architecture and was dropped in the rewrite rebase. The
   candidate loop already handles EACCES/ENOENT/ENOTDIR; ETXTBSY currently
   fails immediately. Data point: Go's model (parent-side resolve + a single
   `execve`) does not retry either, and neither does our win32 side — deciding
   "no retry" would make all three consistent.

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
