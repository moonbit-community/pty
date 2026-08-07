# moonbit-community/pty

Cross-platform PTY (pseudo-terminal) spawning for MoonBit native targets,
integrated with `moonbitlang/async` so reads and writes go through the async
event loop instead of blocking the thread.

## API

```moonbit
@async.with_task_group(group => {
  let pty = @pty.spawn(
    group,
    ["/bin/sh", "-c", "echo hello"],
    cwd="/workspace",
  )
  defer pty.close()

  let output = pty.read_some()            // Pty implements @io.Reader
  pty.write(@utf8.encode("ls\n"))         // async
  pty.resize(cols=120, rows=40)
  let pid : Int = pty.pid()
  let exit_code : Int = pty.wait()
})
```

`@pty.spawn` follows `moonbitlang/async/process.spawn`: it is attached to a
task group, registers the master fd with the async event loop, and returns a
handle that can be used while the child is running. On Unix, `argv[0]` is
resolved via `PATH` using `execvp`; on Windows, the command is launched through
`CreateProcessW`. The optional `cwd` argument sets the child's initial working
directory; when omitted, the child inherits the parent's working directory.

The deprecated method form `Pty::spawn` is kept for compatibility; prefer
`@pty.spawn` in new code.

`Pty::wait` waits for the child process and returns its exit code. `Pty::close`
stops the child and releases PTY resources. A read already in progress may
return buffered shutdown output before finishing with EOF; its task is not
cancelled. `Pty::pid` returns the PID captured at spawn time, including after
`close`, rather than using a numeric sentinel for unavailable native state.
Call `wait` explicitly when the exit code matters.

## Errors

Failures are reported as `@moonbitlang/async/os_error.OSError(code, context~)`,
where `code` is `errno` on Unix or `GetLastError()` on Windows. Use the
`@os_error` predicates such as `is_EACCES`, `is_ENOENT`, and
`is_nonblocking_io_error` to branch on specific kinds:

```moonbit
try {
  @async.with_task_group(group => {
    @pty.spawn(group, ["/bin/missing"])
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
| Windows | ConPTY + `CreateProcessW()` | No fork involved |

## Windows: ConPTY process startup

Windows uses the ConPTY API instead of Unix-style PTYs:

1. Create two synchronous pipes:
   - input pipe: parent writes keyboard input to `inputWriteSide`; ConPTY reads
     from `inputReadSide`
   - output pipe: ConPTY writes screen output to `outputWriteSide`; parent
     reads from `outputReadSide`
2. Call `CreatePseudoConsole(size, inputReadSide, outputWriteSide, ...)`.
3. Prepare `STARTUPINFOEX` with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`.
4. Call `CreateProcessW(..., EXTENDED_STARTUPINFO_PRESENT, ...)`.
5. After `CreateProcessW` succeeds, close `inputReadSide` and
   `outputWriteSide` in the parent. The parent keeps only `inputWriteSide` and
   `outputReadSide` for async I/O.

The child process is launched with `bInheritHandles=FALSE`; the ConPTY handle is
passed through the process-thread attribute list rather than inherited as a raw
handle.

### Why `STARTF_USESTDHANDLES` is set

When the parent process has redirected stdio, for example inside GitHub Actions
or a daemon/logging setup, Windows may otherwise copy those redirected stdio
handles into the child process. In that state, child output can bypass ConPTY
and go directly to the parent's stdout/stderr instead of the PTY output pipe.

To avoid that, the Windows startup path explicitly sets
`STARTF_USESTDHANDLES` with zero-initialized stdio handles. This follows the
same practical pattern used by established ConPTY implementations:

- `microsoft/node-pty` sets `STARTF_USESTDHANDLES`, passes null stdio handles,
  and creates the child with `bInheritHandles=false`.
- `wezterm/portable-pty` sets `STARTF_USESTDHANDLES` and uses invalid stdio
  handles to prevent the child from inheriting redirected parent output handles.

This is separate from the core ConPTY attachment. The actual PTY association is
still made by `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`; `STARTF_USESTDHANDLES`
only prevents inherited stdio redirection from competing with that attachment.

### Windows argv encoding

Windows receives one command-line string rather than an `argv` array. The
Windows path quotes each argument while constructing that command line, then
passes the command line and optional working directory to `CreateProcessW` as
UTF-16. Non-ASCII executable paths, arguments, and working directories
therefore do not depend on the process ANSI code page.

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

The parent also re-spawns with its own executable path and original OS `argv`
as helper-process arguments (separate from the target argv that gets streamed
through the pipe).
This is **required** because in MoonBit debug mode, the current executable can
be `tcc` (MoonBit's native runner), not the test/application binary.
Re-spawning `tcc` without the original arguments means it doesn't know which
compiled module to load; the constructor would never run.

In release mode, MoonBit compiles to a standalone native binary, so
the self command is the actual binary with the constructor baked in. The extra
argv is harmless in that case because the constructor fires before `main()`
parses them.
