# TODO

## Cross-platform API

1. **Unify the shared surface into one non-`#cfg` file.** `#cfg` code is not
   type-checked on the inactive platform, so every declaration written twice is
   a silent drift point — the `argv[0]` divergence, the grace period (item 2),
   and the fd-lifetime bug fixed in d71d642 all came from that. Move `Pty`, the
   `spawn` signature, `wait`/`pid`/`resize` and the Reader/Writer impls into
   `pty.mbt`, leaving a per-platform `priv struct Backend` (verified: a
   `#cfg`-gated `priv struct` can back a field of an ungated struct). Keep
   `spawn`'s body and both `.c` files split — fork+execve and CreateProcessW
   share no structure worth abstracting. The resolver work made the two sides
   structurally symmetric (pure candidate function + platform-side probe), so
   the unification has a natural seam now.
2. Unify the cancellation grace period: win32 sleeps 5000ms before the hard
   kill, unix sleeps 1000ms.

## Unix

3. `moonbit_pty_unix_write_error_exit` now carries `(void)n;` — verify
   `-Wall -Wextra -Wshadow` is clean on both clang/macOS and gcc/Ubuntu CI,
   then drop this item.
4. Decide whether `execve` needs a retry for transient failures
   (e.g. `ETXTBSY`). main's 8c91701 added spawn retries for the old
   helper-based architecture and was dropped in the rewrite rebase. The
   candidate loop already handles EACCES/ENOENT/ENOTDIR; ETXTBSY currently
   fails immediately. Data point: Go's model (parent-side resolve + a single
   `execve`) does not retry either, and neither does our win32 side — deciding
   "no retry" would make all three consistent.

## Build & repo hygiene

5. **Edits to `pty_unix.c` / `pty_win32.c` do not trigger a rebuild.**
   `native-stub` lists only the `pty.c` umbrella, which `#include`s them, and
   moon does not track included files as build inputs — a changed C stub is
   silently served from cache until `moon clean`. Both files already carry
   `#if defined(_WIN32)` / `#if !defined(_WIN32)` guards, so the umbrella can
   be dropped and both `.c` files listed in `native-stub` directly without
   duplicate symbols. (This bit us on every `.c` edit during the win32
   resolver work.)
6. Consider building the `test_data/win32/*.exe` fixtures from their `.c`
   sources in a pre-build step instead of committing compiled binaries.

## Upstream (moonbitlang/async)

7. Propose the win32 userland resolver upstream: async's Windows spawn still
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
