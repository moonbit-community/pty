# moonbit-community/pty

Cross-platform PTY (pseudo-terminal) spawning for MoonBit, on the native and
wasm targets, integrated with `moonbitlang/async` so reads and writes go
through the async event loop instead of blocking the thread.

Each pty is held by a small sidecar process that the library starts and talks
to over pipes, which is what makes the wasm target (programs run with
`moonrun`) work. The sidecar executable for Linux, macOS and Windows on
x86_64/arm64 is embedded in the package and written once to the user's cache
directory; set `PTY_SIDECAR` to the path of one built from
`sidecar/sidecar.c` to use that instead:

```sh
cc -O2 -o pty-sidecar sidecar/sidecar.c                 # Unix
cl /O2 /Fe:pty-sidecar.exe sidecar\sidecar.c            # Windows
```

## Usage

```moonbit
let exit_code = @pty.with_pty(
  "sh", [],
  rows=24, cols=80,
  cwd="/workspace",
) <| pty => {
  let pid : Int = pty.pid()
  pty.resize(rows=40, cols=120)
  pty.write(b"ls\nexit\n")          // Pty implements @io.Writer
  let text = pty.read_all().text()  // ... and @io.Reader
  pty.wait()
}
```

`with_pty` spawns `file` with `args` on a new pseudo-terminal, runs the
callback with its `Pty`, and releases the pty when the callback is done.

The pty lives exactly as long as the callback. If the child is still running
when the callback returns, raises, or is cancelled, it is hung up, given a
5 s grace period, then killed; `with_pty` returns once it has been reaped.
`Pty::wait` returns the child's exit code; call it inside the callback to let
the child finish on its own.

Do not let the `Pty` escape the callback: it is closed afterwards, and a task
still blocked reading it is not woken up.

## Spawning into your own task group: `spawn`

`with_pty` opens a task group of its own. When you already have one whose
lifetime is the pty's — typically a session with tasks reading and writing
concurrently — spawn the pty into it directly with `spawn`, which takes the
group as its first argument and otherwise the same arguments:

```moonbit
@async.with_task_group() <| session => {
  let pty = @pty.spawn(session, "sh", [])
  session.spawn_bg(no_wait=true, () => forward_input(pty))
  while pty.read_some() is Some(chunk) {
    handle(chunk)
  }
}
```

The pty's resources are released when that group exits. If the group is
cancelled, the child gets the same 5 s grace period, then a hard kill.

By default the group waits for the child to exit. Pass `no_wait=true` (same
semantics as `@async/process.spawn`) to let the group exit as soon as its own
tasks are done, terminating the child instead of waiting for it.

Because the pty stays open until its group exits, do not spawn many ptys into
a single long-lived group: their sidecar processes and pipes accumulate. Give
each pty a group of its own, or use `with_pty`.

## Drain the pty concurrently

Do **not** `wait()` first and `read()` afterwards. The output travels through
bounded queues (the pty and the pipe from the sidecar), and a child whose
output nobody reads blocks writing it, so it never exits. Read concurrently
while waiting.

Relatedly, ConPTY output is a screen rendering, not a byte stream: expect VT
escape sequences (including an initial clear-screen) surrounding your child's
output. Strip or escape them before asserting on pty output in tests — a
failing diff that prints raw pty output replays those sequences into your
terminal.

## Further reading

- [docs/internals.md](docs/internals.md) — the sidecar, executable
  resolution, environment merging, and platform architecture: unix
  fork/execve, Windows ConPTY startup, argv encoding.
- [sidecar/README.md](sidecar/README.md) — the sidecar's pipe protocol.
- [docs/invariants.md](docs/invariants.md) — hard-won debugging conclusions
  and decision records that must not regress.
