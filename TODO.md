# TODO

## Cross-platform API

1. Unify the cancellation grace period: win32 sleeps 5000ms before the hard
   kill, unix sleeps 1000ms. (Unifying the whole shared surface into one
   non-`#cfg` file was considered and dropped 2026-08-14 as not worth it; the
   platform-split files are the durable structure, so mind the `#cfg` drift
   risk — inactive-platform code is not type-checked.)

## Unix

2. `moonbit_pty_unix_write_error_exit` now carries `(void)n;` — verify
   `-Wall -Wextra -Wshadow` is clean on both clang/macOS and gcc/Ubuntu CI,
   then drop this item.
3. Decide whether `execve` needs a retry for transient failures
   (e.g. `ETXTBSY`). main's 8c91701 added spawn retries for the old
   helper-based architecture and was dropped in the rewrite rebase. The
   candidate loop already handles EACCES/ENOENT/ENOTDIR; ETXTBSY currently
   fails immediately. Data point: Go's model (parent-side resolve + a single
   `execve`) does not retry either, and neither does our win32 side — deciding
   "no retry" would make all three consistent.

## Windows

4. Audit the win32 `spawn` failure branches for handle double-closes and port
   the unix error-path tests (needs a Windows machine). Context: the unix side
   had a real one — `replica` was closed on the success path AND re-closed in
   the outer catch; the comment claiming "close is idempotent" was wrong
   (`Handle::close` is a bare close(2)/`CloseHandle`), and between the two
   closes the fd number gets recycled, so the second close killed unrelated
   fds. Fixed 2026-08-14 with the `close_replica` guard; the new
   ENOENT/EACCES tests in `pty_unix_test.mbt` were the first to run those
   branches and surfaced it as random EBADF in later tests. On win32 no
   double-close is evident from reading, but those branches have never
   executed. Test notes for the port:
   - "non-existent program" raises ERROR_FILE_NOT_FOUND from the userland
     resolver BEFORE any handle exists, so it exercises no cleanup;
   - to hit the `pid < 0` cleanup branch, spawn a file that resolves but
     cannot start, e.g. a text file named `foo.exe` in a tmpdir
     (ERROR_BAD_EXE_FORMAT, 193);
   - remember the "do not regress" invariant below: `ClosePseudoConsole`
     twice on one HPCON is heap corruption, and the failure branches before
     `hpc` is wrapped in `Ref(Some(...))` close it directly — they must stay
     single-shot.

## Build & repo hygiene

5. Consider building the `test_data/win32/*.exe` fixtures from their `.c`
   sources in a pre-build step instead of committing compiled binaries.

## Upstream (moonbitlang/async)

6. Propose the win32 userland resolver upstream: async's Windows spawn still
   appends `.exe` by suffix match (`foo.bat` → `foo.bat.exe`) and delegates
   the search to `CreateProcessW(NULL, cmdline, ...)`, so `cwd` does not
   participate in locating the executable and the parent's cwd does. See
   README "Executable resolution" for the semantics to port. (The env-merge
   case-insensitivity bug we found was fixed upstream in 0.20.4 — nothing to
   report there.)

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
