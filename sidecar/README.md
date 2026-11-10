# pty sidecar

`sidecar.c` is a small C program that holds one pseudo-terminal on behalf of
a `moonbit-community/pty` program: it opens the terminal, starts the child on
it, and relays everything over its own stdio pipes. The library starts one
per pty with `@async/process`, which is what lets the same MoonBit code run
on the native and the wasm targets. The MoonBit side is `internal/sidecar`.

- Unix: `posix_openpt` + `fork`/`setsid`/`TIOCSCTTY`/`execve`, a
  single-threaded `select` loop, SIGCHLD through a self-pipe.
- Windows: ConPTY, with one thread each for terminal input, terminal output
  and waiting for the child.

The sidecar lives exactly as long as its command pipe. When the pipe closes
(the parent's task group exited, or the parent died) and the child is still
running, the terminal is hung up, the child gets a 5 s grace period, then it
is killed; then the sidecar exits.

## How programs get one

1. The executable named by the `PTY_SIDECAR` environment variable: an
   override for tests, development and hosts where the next step is not
   possible.
2. The executable embedded in `internal/sidecar/sidecars.generated.mbt` for
   the running `<os>-<arch>` (`macos-arm64`, `linux-x86_64`, ...), written
   once to the user's cache directory under a name derived from its content
   and reused from there. The `sidecars` GitHub workflow rebuilds the
   binaries whenever this directory changes on `main` and commits the
   regenerated file back.

Build a standalone sidecar with any C compiler:

```sh
cc -O2 -Wall -o pty-sidecar sidecar/sidecar.c        # Unix
cl /O2 /Fe:pty-sidecar.exe sidecar\sidecar.c        # Windows
```

## Protocol

| channel | direction | content |
|---|---|---|
| stdin | parent → sidecar | command frames |
| stdout | sidecar → parent | the terminal's output, raw; EOF once the terminal is done or hung up |
| stderr | sidecar → parent | event frames |

Frames are `tag:u8 len:u32le payload`; integers are little-endian.

| tag | command | payload |
|---|---|---|
| `0x01` | SPAWN | see below; must be the first command, and only once |
| `0x02` | WRITE | bytes for the terminal's input |
| `0x03` | RESIZE | `u16` rows, `u16` cols |
| `0x04` | HANGUP | none: close the terminal (SIGHUP to the child's session on Unix, `ClosePseudoConsole` on Windows) |
| `0x05` | KILL | none: SIGKILL to the child's process group on Unix, `TerminateJobObject` on Windows |

| tag | event | payload |
|---|---|---|
| `0x80` | SPAWNED | `i32` child pid |
| `0x81` | SPAWN_FAILED | `i32` OS error code (`errno` / `GetLastError()`); the sidecar exits |
| `0x82` | WROTE | `i32` bytes of earlier WRITEs that reached the terminal |
| `0x83` | WRITE_FAILED | `i32` OS error code; queued input was dropped |
| `0x84` | RESIZED | `i32` OS error code, 0 on success; one per RESIZE, in order |
| `0x85` | EXIT | `i32` the child's exit code, or `-signal` |
| `0x86` | FAILED | `i32` OS error code, then a UTF-8 message: the sidecar itself failed |

SPAWN carries `u32` protocol version (1), `u16` rows, `u16` cols, then four
string lists, each a `u32` count followed by `u32 len, bytes` strings:

- candidates: executables to try in order (Unix, with `execve`), or to
  expand with `GetFullPathNameW` and probe for existence (Windows);
- argv: the child's argv (Unix), or exactly one string, the command line
  (Windows);
- env: the child's whole environment as `KEY=VALUE`;
- cwd: zero strings for the sidecar's own directory, or one.

The parent keeps at most 64 KiB of WRITE payload unacknowledged, which bounds
the sidecar's input queue and makes writes to a child that does not read
block. The sidecar always keeps reading commands, so HANGUP and KILL are
never stuck behind queued input.
