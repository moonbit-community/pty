# TODO

## Cross-platform API

1. **Unify the shared surface into one non-`#cfg` file.** `#cfg` code is not
   type-checked on the inactive platform, so every declaration written twice is
   a silent drift point — the `argv[0]` divergence, the grace period (item 3),
   and the fd-lifetime bug fixed in d71d642 all came from that. Move `Pty`, the
   `spawn` signature, `wait`/`pid`/`resize` and the Reader/Writer impls into
   `pty.mbt`, leaving a per-platform `priv struct Backend` (verified: a
   `#cfg`-gated `priv struct` can back a field of an ungated struct). Keep
   `spawn`'s body and both `.c` files split — fork+execve and CreateProcessW
   share no structure worth abstracting.
2. Windows does not append `.exe` when `file` has no extension, while
   moonbitlang/async does. `CreateProcessW` appends it during its own search,
   but only when the name has no dot at all — `foo.bar` is searched verbatim
   and fails. Decide whether to match async here.
3. Unify the cancellation grace period: win32 sleeps 5000ms before the hard
   kill, unix sleeps 1000ms.

## Unix

4. Silence the unused-variable warning in `moonbit_pty_unix_write_error_exit`
   (`ssize_t n = write(...)`); it is the only warning left under
   `-Wall -Wextra -Wshadow`, on both clang/macOS and gcc/Ubuntu.
5. Decide whether `execve` needs a retry for transient failures
   (e.g. `ETXTBSY`). main's 8c91701 added spawn retries for the old
   helper-based architecture and was dropped in the rewrite rebase. The
   candidate loop already handles EACCES/ENOENT/ENOTDIR; ETXTBSY currently
   fails immediately.

## Build & repo hygiene

6. **Edits to `pty_unix.c` / `pty_win32.c` do not trigger a rebuild.**
   `native-stub` lists only the `pty.c` umbrella, which `#include`s them, and
   moon does not track included files as build inputs — a changed C stub is
   silently served from cache until `moon clean`. Both files already carry
   `#if defined(_WIN32)` / `#if !defined(_WIN32)` guards, so the umbrella can
   be dropped and both `.c` files listed in `native-stub` directly without
   duplicate symbols.
7. Add a `.gitattributes` (`* text=auto eol=lf`). `pty_win32.mbt` and
   `pty_win32.c` are stored with CRLF while everything else is LF, so a plain
   `moon fmt` on unix rewrites every line of `pty_win32.mbt`.
   `moon fmt --check` does not flag this, so CI stays green either way.

## Docs

8. Rewrite `README.md`: it still describes the old `openpty()` + helper
   self-spawn architecture, which the rewrite replaced with fork+execve on
   unix and ConPTY on Windows. Known-stale as of a517001:
   - shows `defer pty.close()`, but `Pty::close` was removed in acb69d0;
   - mentions a deprecated `Pty::spawn` method form that no longer exists;
   - shows `spawn` taking a single argv array, but the signature is now
     `file + args` (`StringView, ArrayView[StringView]`);
   - says unix resolves via "`execvp`", but it is now our own execve loop
     over PATH candidates;
   - the "Platform strategies" table and the whole "macOS: the mimalloc +
     fork problem" section argue fork is impossible, which contradicts the
     current fork+execve design.
9. Document that a script needs a shebang. `execvp` (hence
   moonbitlang/async's `posix_spawnp`) falls back to running `/bin/sh` when
   `execve` returns ENOEXEC — a pre-`#!` compatibility behavior inherited from
   the shell. We deliberately do **not** match it: `execve` is called directly,
   so an extension-less, shebang-less script fails with ENOEXEC instead of
   silently running under `sh`. Rebuilding the argv for the fallback would
   also mean allocating in the forked child, which is not permitted here.
10. Document that the pty must be drained concurrently: **do not `wait()`
    and then `read()`**. A pty master is a bounded kernel queue, and on macOS
    the kernel discards whatever is still queued a few hundred milliseconds
    after the child exits (measured: readable at 600ms, gone at 800ms,
    unaffected by when the child is reaped). Reading late yields a clean but
    empty EOF.

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
