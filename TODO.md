# TODO

## Cross-platform API

1. **`args` means different things on the two platforms.** Windows follows
   moonbitlang/async: `file` is the program and becomes `argv[0]`, `args` are
   the *remaining* arguments — `spawn(g, "moon", ["version"])`. Unix resolves
   `file` to a path but then passes `args` to `execve` as the *full* `argv`,
   so its test reads `spawn(g, "/bin/echo", ["echo", "hello"])`. Align unix to
   the async model: `execve(resolved_path, [file, ..args], envp)`, and update
   `pty_test.mbt`.
2. **Unify the shared surface into one non-`#cfg` file.** `#cfg` code is not
   type-checked on the inactive platform, so every declaration written twice is
   a silent drift point — items 1, 5 and the fd-lifetime bug fixed in d71d642
   all came from that. Move `Pty`, the `spawn` signature, `wait`/`pid`/`resize`
   and the Reader/Writer impls into `pty.mbt`, leaving a per-platform
   `priv struct Backend` (verified: a `#cfg`-gated `priv struct` can back a
   field of an ungated struct). Keep `spawn`'s body and both `.c` files split —
   fork+execve and CreateProcessW share no structure worth abstracting.

## Unix (needs a unix machine to fix & verify)

3. `moonbit_pty_is_executable` returns 0 with a stale `errno` when the path
   exists but is not a regular file; set `errno` explicitly so
   `resolve_path` reports a meaningful error.
4. Silence the unused-variable warning in `moonbit_pty__fork_fail`
   (`ssize_t n = write(...)`); it is the only warning left under
   `-Wall -Wextra -Wshadow`, on both clang/macOS and gcc/Ubuntu.
5. Unify the cancellation grace period: win32 sleeps 5000ms before the hard
   kill, unix sleeps 1000ms.
6. Decide whether `execve` needs a retry for transient failures
   (e.g. `ETXTBSY`). main's 8c91701 added spawn retries for the old
   helper-based architecture and was dropped in the rewrite rebase.

## Build & repo hygiene

7. **Edits to `pty_unix.c` / `pty_win32.c` do not trigger a rebuild.**
   `native-stub` lists only the `pty.c` umbrella, which `#include`s them, and
   moon does not track included files as build inputs — a changed C stub is
   silently served from cache until `moon clean`. Both files already carry
   `#if defined(_WIN32)` / `#if !defined(_WIN32)` guards, so the umbrella can
   be dropped and both `.c` files listed in `native-stub` directly without
   duplicate symbols.
8. Add a `.gitattributes` (`* text=auto eol=lf`). `pty_win32.mbt` and
   `pty_win32.c` are stored with CRLF while everything else is LF, so a plain
   `moon fmt` on unix rewrites every line of `pty_win32.mbt`.
   `moon fmt --check` does not flag this, so CI stays green either way.
9. `_unused_packages` at the bottom of `pty_win32.mbt` has no `#cfg` guard, so
   its `ignore(...)` calls also run on unix, where those imports are genuinely
   used.
10. `pkg.generated.mbti` carries one trailing blank line that `moon info` on
    macOS removes, so the "regenerate and `git diff --exit-code`" CI job is red
    on unix. Regenerate it from whichever toolchain CI uses and commit that.

## Docs

11. Rewrite `README.md`: it still describes the old `openpty()` + helper
    self-spawn architecture, which the rewrite replaced with fork+execve
    on unix and ConPTY on Windows.
12. Document that the pty must be drained concurrently: **do not `wait()`
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
