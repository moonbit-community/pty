# tonyfettes/pty

Cross-platform PTY (pseudo-terminal) spawning for MoonBit native targets,
integrated with `moonbitlang/async` so reads and writes go through the async
event loop instead of blocking the thread.

Extracted from `tonyfettes/tun-poc-server`'s `server/pty` package.

## API

```moonbit
@async.with_task_group(group => {
  let pty = @pty.Pty::spawn(group, ["/bin/sh", "-c", "echo hello"])
  defer pty.close()

  let reader = pty.reader()               // @raw_fd.RawFd
  pty.write(@utf8.encode("ls\n"))         // async
  pty.resize(120, 40)
  let pid : Int = pty.pid()
  let exit_code : Int = pty.wait()
})
```

`Pty::spawn` follows `moonbitlang/async/process.spawn`: it is attached to a
task group, registers the master fd with the async event loop, and returns a
handle that can be used while the child is running. `argv[0]` is resolved via
`PATH` (`execvp`).

## Errors

Failures are reported as `@moonbitlang/async/os_error.OSError(code, context~)`,
where `code` is `errno` on Unix or `GetLastError()` on Windows. Use the
package's `is_EACCES`, `is_ENOENT`, `is_nonblocking_io_error`, etc. predicates
to branch on specific kinds:

```moonbit
try {
  @async.with_task_group(group => {
    @pty.Pty::spawn(group, ["/bin/missing"])
  })
} catch {
  err is @os_error.OSError if err.is_ENOENT() => ...
  err => raise err
}
```

## Platform strategies

| Platform | Method | Why |
|----------|--------|-----|
| macOS | `openpty()` + `moonbitlang/async` self-spawn helper | avoids `fork()` with mimalloc |
| Linux | `openpty()` + `moonbitlang/async` self-spawn helper | shares the async process spawn path |
| Windows | ConPTY + `CreateProcessA()` | No fork involved |

## macOS: the mimalloc + fork problem

MoonBit's release builds ship with mimalloc as the default allocator. On macOS,
mimalloc registers itself as a custom malloc zone. When `fork()` is called,
`libSystem_atfork_child` iterates all registered malloc zones in the child and
calls their introspection callbacks. mimalloc's `mi_introspect` struct has a
NULL function pointer for one of these callbacks, causing the child to segfault
(signal 11, exit code 139) before it ever reaches `exec()`.

Reproduction results (linking a minimal C `forkpty()` program with/without
`libmoonbitrun.o`):

| Variant | Without runtime | With libmoonbitrun.o |
|---------|----------------|---------------------|
| `forkpty()` on main thread | works | child exits 139 (SIGSEGV) |
| `forkpty()` in a pthread | works | child exits 139 (SIGSEGV) |
| `posix_spawn()` self-helper | works | works |
| MoonBit release without mimalloc | works | n/a |

A pthread does not help, because `pthread_atfork` child handlers are
process-wide — the child inherits the same malloc zones with the same NULL
function pointer regardless of which thread called `fork()`.

## Unix: the self-helper pattern

On macOS and Linux, this package leaves process creation to
`moonbitlang/async/process.spawn`. The C side only owns PTY setup and the
constructor that runs in helper mode before `main()`.

Plumbing between parent and helper uses one env var plus stdio redirection:

1. `openpty()` creates a PTY pair (master + slave fd).
2. The parent creates two pipes — `argv_pipe` (parent → helper) and `err_pipe`
   (helper → parent) — and a dummy pipe write end whose fd is rebound to the
   PTY slave with `dup2(slave, dummy_write.fd())`.
3. `spawn` launches the current command inside the caller's task group with:
   - `stdin=argv_pipe.read`
   - `stdout=dummy_write` (now the PTY slave fd)
   - `stderr=err_pipe.write`
   - `MOONBIT_PTY_EXEC=stdio`
4. The constructor detects helper mode, duplicates stderr to keep the error
   pipe, treats fd 0 as argv input and fd 1 as the PTY slave, then calls
   `login_tty(1)`.
5. The parent streams the target `argv` (flattened as `arg0\0arg1\0…argN\0`)
   into `argv_pipe` and closes its write end.
6. The constructor reads argv from `argv_pipe` until EOF,
   arms `FD_CLOEXEC` on its copy of the error pipe, and `execvp()`s. A
   successful exec auto-closes the error pipe so the parent sees EOF; any
   pre-exec failure writes the errno to the pipe and `_exit()`s.
7. The parent reads from the error pipe: 4 bytes → failure with that errno,
   EOF → success.

### Why argv must be copied

The parent also re-spawns with its own executable path and `argv` from
`tonyfettes/os` as helper-process arguments (separate from the target argv
that gets streamed through the pipe).
This is **required** because in MoonBit debug mode, the current executable can
be `tcc` (MoonBit's native runner), not the test/application binary.
Re-spawning `tcc` without the original arguments means it doesn't know which
compiled module to load; the constructor would never run.

In release mode, MoonBit compiles to a standalone native binary, so
the self command is the actual binary with the constructor baked in. The extra
argv is harmless in that case because the constructor fires before `main()`
parses them.
