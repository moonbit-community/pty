# moonbit-community/pty

Cross-platform PTY (pseudo-terminal) spawning for MoonBit native targets,
integrated with `moonbitlang/async` so reads and writes go through the async
event loop instead of blocking the thread.

## API

```moonbit
@async.with_task_group(group => {
  let pty = @pty.spawn(
    group,
    "sh", [],
    rows=24, cols=80,
    cwd="/workspace",
  )
  let pid : Int = pty.pid()
  pty.resize(rows=40, cols=120)
  pty.write(b"ls\nexit\n")          // Pty implements @io.Writer
  let text = pty.read_all().text()  // ... and @io.Reader
  let exit_code : Int = pty.wait()
})
```

The pty's resources are released when the task group exits. On cancellation
the child gets a 5 s grace period, then a hard kill. `Pty::wait` returns the
child's exit code; call it explicitly when the exit code matters.

By default the task group waits for the child to exit. Pass `no_wait=true`
(same semantics as `@async/process.spawn`) to let the group exit as soon as
its own tasks are done, terminating the child instead of waiting for it.

## Scoped sessions: `with_pty`

`spawn` keeps the pty open until its task group exits, so a long-lived group
that spawns many ptys accumulates their file descriptors. When a pty's
lifetime is a lexical scope, use `with_pty` instead: it takes the same
arguments as `spawn` (minus `group` and `no_wait`) and releases the pty as
soon as the callback is done.

```moonbit
let (text, exit_code) = @pty.with_pty("sh", ["-c", "echo hello"], pty => {
  let text = pty.read_all().text()
  (text, pty.wait())
})
```

If the child is still running when the callback returns, raises, or is
cancelled, it is hung up, given the 5 s grace period, then killed; `with_pty`
returns once it has been reaped. Call `pty.wait()` inside the callback to let
the child finish on its own.

Do not let the `Pty` escape the callback: it is closed afterwards, and a task
still blocked reading it is not woken up. Tasks that read or write
concurrently belong in a task group opened inside the callback.

Use `spawn` when the pty must outlive the code that created it, or should
share the lifetime of a task group you already have.

## Drain the pty concurrently

Do **not** `wait()` first and `read()` afterwards. A pty master is a bounded
kernel queue, and on macOS the kernel discards whatever is still queued a few
hundred milliseconds after the child exits. Read concurrently while waiting;
reading late yields a clean but empty EOF.

Relatedly, ConPTY output is a screen rendering, not a byte stream: expect VT
escape sequences (including an initial clear-screen) surrounding your child's
output. Strip or escape them before asserting on pty output in tests — a
failing diff that prints raw pty output replays those sequences into your
terminal.

## Further reading

- [docs/internals.md](docs/internals.md) — executable resolution, environment
  merging, and platform architecture: unix fork/execve, Windows ConPTY
  startup, argv encoding.
- [docs/invariants.md](docs/invariants.md) — hard-won debugging conclusions
  and decision records that must not regress.
