# Platform internals

How `@pty.spawn` works on each platform: executable resolution, environment
merging, and process startup.

## Executable resolution

Both platforms resolve `file` with the same rule, following libuv and Go
rather than each platform's ambient default:

- **Absolute path** — used as-is.
- **Relative path containing a separator** — resolved against `cwd` (or the
  parent's current directory when `cwd` is omitted). Never searched in PATH.
- **Bare name** — searched through the `PATH` of the *child's* merged
  environment (`inherit_env` + `extra_env`); first match wins. Empty entries
  (a leading or trailing separator, a doubled one, or an empty `PATH`) are
  skipped, so an empty `PATH` means a bare name is simply not found. A
  *missing* `PATH` is also not found on Windows; unix falls back to
  `/usr/bin:/bin`, as `execvp` does.

A `file` that cannot be resolved raises before any process or ConPTY is
created. Failures throughout the library are the usual
`@moonbitlang/async/os_error.OSError(code, context~)`, with `code` taken
from `errno` on unix and `GetLastError()` on Windows.

### Windows drive-letter forms

Windows additionally handles the drive-letter forms, with the same semantics
as Go's `joinExeDirAndFName` and libuv's `search_path`:

| form | resolves to |
|------|-------------|
| `\\server\share\x`, `\\?\...`, `//server/share/x` | as-is (UNC/device paths are absolute by construction) |
| `C:\x`, `C:/x` | as-is |
| `\x`, `/x` (root-relative) | the root of `cwd`'s drive |
| `C:x` when `cwd` is on `C:` | joined to `cwd` |
| `C:x` when `cwd` is on another drive or a UNC path | expanded by `GetFullPathNameW` against the parent's state — a per-drive current directory is parent state by construction, so no child-side answer exists |

`.exe` is appended when the last path component has no extension
(`foo` → `foo.exe`; `foo.bat`, `foo.`, and `python3.12` stay verbatim) — the
same rule `CreateProcessW`'s own search applies. Candidates are probed with
`GetFileAttributesW`; the first existing non-directory is passed to
`CreateProcessW` as `lpApplicationName`, so `CreateProcessW` performs no
search of its own. (Its native search never consults `lpCurrentDirectory`
and does consult the parent's current directory — which is why this library
resolves in userland at all.)

### Deliberate divergences

Documented so they stay deliberate:

- **No PATHEXT.** A bare `foo` only ever tries `foo.exe`. PATHEXT is a
  cmd.exe convention; most of its entries (`.vbs`, `.js`, `.msc`, …) cannot
  be executed by `CreateProcessW` anyway, and implicitly resolving bare names
  to `.bat`/`.cmd` is the BatBadBut (CVE-2024-24576) argument-injection
  shape. Spawn batch files by explicit name, and do not pass untrusted
  arguments to them: cmd.exe parses them under different quoting rules than
  `CommandLineToArgvW`, and this library escapes for the latter.
- **An empty `PATH` entry is not the current directory.** `execvp` reads
  `PATH=:/bin`, `/bin:`, or an empty `PATH` as "also search the current
  directory", which silently lets a bare name run whatever sits in `cwd`.
  This library skips empty entries on both platforms; to search `cwd`, name
  it explicitly (`.` in `PATH`, or `./prog` as `file`). Go's `LookPath`
  refuses the implicit form for the same reason.
- **Unix keeps searching past an `EACCES` candidate (execvp semantics);
  Windows stops at the first existing match** and lets `CreateProcessW`
  report `ERROR_ACCESS_DENIED` or `ERROR_BAD_EXE_FORMAT`. Windows has no
  execute bit — a faithful check would be an `AccessCheck` per candidate for
  a situation PATH directories rarely exhibit. Go and libuv choose the same.
- **Scripts need a shebang on unix.** The child calls `execve` directly and
  does not reproduce `execvp`'s historical `ENOEXEC` → `/bin/sh` fallback
  (which would also require allocating in the forked child — see below). A
  shebang-less script fails with `ENOEXEC` instead of silently running
  under `sh`.

## Environment

`inherit_env=true` (the default) starts from the parent's environment and
merges `extra_env` on top. On Windows the merge is case-insensitive:
`extra_env={"PATH": ...}` overrides an inherited `Path`, the inherited key's
casing is preserved, and the serialized block contains each variable exactly
once. (Windows compares environment keys ordinal-ignore-case; the merge
uses Unicode `to_upper` — a divergence only conceivable for exotic
non-ASCII keys.)

## Unix: fork + execve

The parent opens the pty pair (`open("/dev/ptmx")`/`grantpt`/`unlockpt`) and
prepares everything the child will need — encoded argv, envp, and the PATH
candidate list — *before* forking, because the forked child does only
async-signal-safe work and never allocates. The child then: `setsid`, adopts
the replica as controlling terminal (`TIOCSCTTY`), `dup2`s it onto stdio,
`chdir(cwd)` (this is why relative paths resolve against `cwd`), and tries
`execve` over the prepared candidates, skipping `EACCES`/`ENOENT`/`ENOTDIR`.
Any pre-exec failure writes its errno to an error pipe and `_exit`s; a
successful exec closes the pipe via `FD_CLOEXEC`, so the parent reads either
4 bytes (failure, with errno) or EOF (success).

## Windows: ConPTY process startup

Windows uses the ConPTY API instead of unix-style PTYs:

1. Create two synchronous pipes:
   - input pipe: parent writes keyboard input to `inputWriteSide`; ConPTY reads
     from `inputReadSide`
   - output pipe: ConPTY writes screen output to `outputWriteSide`; parent
     reads from `outputReadSide`
2. Call `CreatePseudoConsole(size, inputReadSide, outputWriteSide, ...)`.
3. Prepare `STARTUPINFOEX` with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`.
4. Call `CreateProcessW(app, cmd, ..., EXTENDED_STARTUPINFO_PRESENT, ...)`,
   where `app` is the resolved executable (`lpApplicationName`) and `cmd` is
   the command line whose argv[0] is the caller's `file` verbatim.
5. After `CreateProcessW` succeeds, close `inputReadSide` and
   `outputWriteSide` in the parent. The parent keeps only `inputWriteSide`
   and `outputReadSide` for async I/O.

The child is launched with `bInheritHandles=FALSE`; the ConPTY handle is
passed through the process-thread attribute list rather than inherited as a
raw handle. The child is placed in a kill-on-close job object so cancellation
can terminate the whole process tree.

### Why `STARTF_USESTDHANDLES` is set

When the parent process has redirected stdio, for example inside GitHub
Actions or a daemon/logging setup, Windows may otherwise copy those
redirected stdio handles into the child process. In that state, child output
can bypass ConPTY and go directly to the parent's stdout/stderr instead of
the PTY output pipe.

To avoid that, the Windows startup path explicitly sets
`STARTF_USESTDHANDLES` with zero-initialized stdio handles. This follows the
same practical pattern used by established ConPTY implementations:

- `microsoft/node-pty` sets `STARTF_USESTDHANDLES`, passes null stdio
  handles, and creates the child with `bInheritHandles=false`.
- `wezterm/portable-pty` sets `STARTF_USESTDHANDLES` and uses invalid stdio
  handles to prevent the child from inheriting redirected parent output
  handles.

This is separate from the core ConPTY attachment. The actual PTY association
is still made by `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`;
`STARTF_USESTDHANDLES` only prevents inherited stdio redirection from
competing with that attachment.

## Wasm: the sidecar backend

A wasm build has no C FFI, and `moonbitlang/async/raw_fd` — the package the
native backends use for asynchronous I/O on a pty master — supports the native
target only. The root `pty` package therefore stays native-only: once
`raw_fd` appears anywhere in its dependency graph, `moon check --target wasm`
refuses the build ("incompatible with the dependency graph"), no matter which
files are `#cfg`-ed out.

The wasm backend is the separate package `moonbit-community/pty/wasm`, which
offers the same public API (`spawn`, `with_pty`, `Pty`, `Pty::wait`,
`Pty::pid`, `Pty::resize`, `@async/io.Reader`/`Writer`). Downstream code
aliases it to `@pty`:

```moonbit
import {
  "moonbit-community/pty/wasm" @pty,
}
```

A wasm module cannot open a pseudo-terminal itself, but it can start a native
process. One sidecar process per pty (`sidecar/sidecar.c`) owns the pty pair
and the child, and relays both over its stdio pipes:

1. The parent sends a SPAWN frame: the terminal size, the PATH candidates, the
   child's argv and environment block, and its working directory.
2. The sidecar opens `/dev/ptmx`, forks, and execs the child into the replica
   (`setsid`, `TIOCSCTTY`, `dup2`, `chdir`) — the same startup sequence as the
   native unix backend, including the ETXTBSY retry and the error pipe.
3. It answers with HELLO carrying the child's pid, then forwards master output
   as OUTPUT frames while accepting WRITE and RESIZE frames.
4. When the child exits it drains the master, reports EXIT with the child's
   exit code (or `-signal`), and exits.

EOF on the command pipe — what the parent produces when its task group exits
— hangs up the terminal, gives the child the same 5 s grace period the native
backends give, kills its process group, and exits. The parent reaps the
sidecar, so no zombie is left behind.

Build the sidecar with any C compiler; it needs no MoonBit runtime:

```sh
cc -O2 -Wall -o sidecar/sidecar sidecar/sidecar.c
PTY_SIDECAR="$PWD/sidecar/sidecar" moon test --target wasm
```

### Protocol

Frames are `tag:u8 len:u32le payload`, spoken on the sidecar's stdin
(commands) and stdout (events). Integers are little-endian `u32`.

| direction | tag | payload |
|---|---|---|
| parent → sidecar | `0x01 SPAWN` | `rows, cols`, then three length-prefixed string arrays (`count`, then `len + bytes` each) for PATH candidates, argv, and `K=V` environment entries, then `cwdlen + bytes` (0 = inherit) |
| parent → sidecar | `0x02 WRITE` | bytes for the pty master |
| parent → sidecar | `0x03 RESIZE` | `rows, cols` |
| parent → sidecar | `0x04 KILL` | optional signal, `SIGKILL` when absent (reserved: the wasm client always shuts down by closing the command pipe) |
| sidecar → parent | `0x80 HELLO` | `version (1), pid` |
| sidecar → parent | `0x81 OUTPUT` | bytes read from the pty master |
| sidecar → parent | `0x82 EXIT` | status: exit code, or `-signal` |
| sidecar → parent | `0x83 ERROR` | `errno`, UTF-8 message |

### Differences from the native backends

- The executable comes from the `PTY_SIDECAR` environment variable only; there
  is no embedded binary yet. Without it `spawn` raises `OSError(ENOTSUP)`.
- `resize` is synchronous in the API but asynchronous underneath: it queues a
  frame for the command pump, so it is ordered before a `write` issued after
  it, and reports `EBADF` once the pty is closed. A failure inside the sidecar
  that surfaces later arrives as an `ERROR` frame on the next read.
- Commands are queued without a bound, so a writer that outruns a child which
  never reads its input buffers in memory instead of blocking as the native
  backends do.
- Only unix hosts are supported: the sidecar uses `fork`/`execve` and a
  `/dev/ptmx` pty. A wasm program on a Windows host has no sidecar to run.
- Teardown is bounded: after closing the command pipe the sidecar hangs up,
  runs the 5 s grace period, kills the group and exits, and its final flush
  gives up after that same period, so a parent that stopped reading cannot
  keep it alive. The parent drains whatever the sidecar still sends and then
  reaps it.
