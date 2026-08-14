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

`file` and `args` become the child's argv. `file` is passed as `argv[0]`
verbatim on both platforms — busybox-style multi-call binaries that dispatch
on `argv[0]` see exactly what you wrote — while the executable actually
launched is found by the resolution rules below.

The pty's resources are released when the task group exits. On cancellation
the child gets a grace period, then a hard kill (currently 1 s on unix and
5 s on Windows; unifying the two is tracked in TODO.md). `Pty::wait` returns
the child's exit code; call it explicitly when the exit code matters.

## Executable resolution

Both platforms resolve `file` with the same rule, following libuv and Go
rather than each platform's ambient default:

- **Absolute path** — used as-is.
- **Relative path containing a separator** — resolved against `cwd` (or the
  parent's current directory when `cwd` is omitted). Never searched in PATH.
- **Bare name** — searched through the `PATH` of the *child's* merged
  environment (`inherit_env` + `extra_env`); first match wins. An empty or
  missing `PATH` means a bare name is simply not found.

Windows additionally handles the drive-letter forms, with the same semantics
as Go's `joinExeDirAndFName` and libuv's `search_path`:

| form | resolves to |
|------|-------------|
| `\\server\share\x`, `\\?\...`, `//server/share/x` | as-is (UNC/device paths are absolute by construction) |
| `C:\x`, `C:/x` | as-is |
| `\x`, `/x` (root-relative) | the root of `cwd`'s drive |
| `C:x` when `cwd` is on `C:` | joined to `cwd` |
| `C:x` when `cwd` is on another drive or a UNC path | expanded by `GetFullPathNameW` against the parent's state — a per-drive current directory is parent state by construction, so no child-side answer exists |

On Windows, `.exe` is appended when the last path component has no extension
(`foo` → `foo.exe`; `foo.bat`, `foo.`, and `python3.12` stay verbatim) — the
same rule `CreateProcessW`'s own search applies. Candidates are probed with
`GetFileAttributesW`; the first existing non-directory is passed to
`CreateProcessW` as `lpApplicationName`, so `CreateProcessW` performs no
search of its own. (Its native search never consults `lpCurrentDirectory`
and does consult the parent's current directory — which is why this library
resolves in userland at all.)

Deliberate divergences, documented so they stay deliberate:

- **No PATHEXT.** A bare `foo` only ever tries `foo.exe`. PATHEXT is a
  cmd.exe convention; most of its entries (`.vbs`, `.js`, `.msc`, …) cannot
  be executed by `CreateProcessW` anyway, and implicitly resolving bare names
  to `.bat`/`.cmd` is the BatBadBut (CVE-2024-24576) argument-injection
  shape. Spawn batch files by explicit name, and do not pass untrusted
  arguments to them: cmd.exe parses them under different quoting rules than
  `CommandLineToArgvW`, and this library escapes for the latter.
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

## Drain the pty concurrently

Do **not** `wait()` first and `read()` afterwards. A pty master is a bounded
kernel queue, and on macOS the kernel discards whatever is still queued a few
hundred milliseconds after the child exits (measured: readable at 600 ms,
gone at 800 ms, unaffected by when the child is reaped). Read concurrently
while waiting; reading late yields a clean but empty EOF.

Relatedly, ConPTY output is a screen rendering, not a byte stream: expect VT
escape sequences (including an initial clear-screen) surrounding your child's
output. Strip or escape them before asserting on pty output in tests — a
failing diff that prints raw pty output replays those sequences into your
terminal.

## Errors

Failures are reported as `@moonbitlang/async/os_error.OSError(code, context~)`,
where `code` is `errno` on unix or `GetLastError()` on Windows. A `file` that
cannot be resolved raises before any process or ConPTY is created. Use the
`@os_error` predicates to branch on specific kinds:

```moonbit
try {
  @async.with_task_group(group => {
    @pty.spawn(group, "missing-program", [])
  })
} catch {
  err is @os_error.OSError if err.is_ENOENT() => ...
  err => raise err
}
```

## Platform architecture

### Unix: fork + execve

The parent opens the pty pair (`posix_openpt`/`grantpt`/`unlockpt`) and
prepares everything the child will need — encoded argv, envp, and the PATH
candidate list — *before* forking, because the forked child does only
async-signal-safe work and never allocates. The child then: `setsid`, adopts
the replica as controlling terminal (`TIOCSCTTY`), `dup2`s it onto stdio,
`chdir(cwd)` (this is why relative paths resolve against `cwd`), and tries
`execve` over the prepared candidates, skipping `EACCES`/`ENOENT`/`ENOTDIR`.
Any pre-exec failure writes its errno to an error pipe and `_exit`s; a
successful exec closes the pipe via `FD_CLOEXEC`, so the parent reads either
4 bytes (failure, with errno) or EOF (success).

### Windows: ConPTY process startup

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

#### Why `STARTF_USESTDHANDLES` is set

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

#### Windows argv encoding

Windows receives one command-line string rather than an argv array. The
command line is built by quoting each argument so that `CommandLineToArgvW`
(and the C runtime's argv parser) recovers it verbatim, then passed to
`CreateProcessW` as UTF-16 alongside the resolved `lpApplicationName`.
Non-ASCII executable paths, arguments, and working directories therefore do
not depend on the process ANSI code page.
