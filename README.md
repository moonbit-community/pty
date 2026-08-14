# moonbit-community/pty

Cross-platform PTY (pseudo-terminal) spawning for MoonBit native targets,
integrated with `moonbitlang/async` so reads and writes go through the async
event loop instead of blocking the thread.

## API

```moonbit
@async.with_task_group(group => {
  let pty = @pty.spawn(
    group,
    "sh", ["-c", "echo hello"],
    rows=24, cols=80,
    cwd="/workspace",
  )
  let text = pty.read_all().text()  // Pty implements @io.Reader
  pty.write(b"ls\n")                // ... and @io.Writer
  pty.resize(rows=40, cols=120)
  let pid : Int = pty.pid()
  let exit_code : Int = pty.wait()
})
```

The pty's resources are released when the task group exits. On cancellation
the child gets a 5 s grace period, then a hard kill. `Pty::wait` returns the
child's exit code; call it explicitly when the exit code matters.

By default the task group waits for the child to exit. Pass `no_wait=true`
(same semantics as `@async/process.spawn`) to let the group exit as soon as
its own tasks are done, terminating the child instead of waiting for it.

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
