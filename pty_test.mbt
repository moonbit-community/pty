///|
// Most tests spawn POSIX-only programs (`/bin/sh`, `/bin/cat`, bare `sh`).
// Windows has dedicated ConPTY smoke tests that use `cmd.exe`.

///|
/// Read from the PTY until `needle` appears in the accumulated output or
/// the timeout fires. Returns `Some(output)` if the needle appeared, `None`
/// otherwise.
async fn read_until_contains(
  pty : Pty,
  needle : String,
  timeout_ms? : Int = 3000,
  max_reads? : Int = 8,
) -> String? {
  let reader = pty.reader()
  let buf : FixedArray[Byte] = FixedArray::make(256, b'\x00')
  let mut output = ""
  let mut found = false
  @async.with_timeout(timeout_ms, () => {
    for _ in 0..<max_reads {
      let n = reader.read(buf)
      if n <= 0 {
        break
      }
      output = output + @utf8.decode(Bytes::from_array(buf[:n]))
      if output.contains(needle) {
        found = true
        break
      }
    }
  })
  if found {
    Some(output)
  } else {
    None
  }
}

///|
#cfg(not(platform="windows"))
async test "spawn succeeds and reports a child pid" {
  @async.with_task_group(group => {
    let pty = @pty.spawn(group, ["/bin/sh"])
    defer pty.close()
    assert_true(pty.pid() > 0)
  })
}

///|
#cfg(not(platform="windows"))
async test "cat echoes input through PTY" {
  @async.with_task_group(group => {
    let pty = @pty.spawn(group, ["/bin/cat"])
    defer pty.close()
    pty.write(@utf8.encode("ping\n"))
    assert_true(read_until_contains(pty, "ping") is Some(_))
  })
}

///|
#cfg(not(platform="windows"))
async test "sh accepts commands through PTY" {
  @async.with_task_group(group => {
    let pty = @pty.spawn(group, ["/bin/sh"])
    defer pty.close()
    pty.write(@utf8.encode("echo READY\nexit\n"))
    assert_true(read_until_contains(pty, "READY") is Some(_))
  })
}

///|
#cfg(not(platform="windows"))
async test "idle PTY read waits instead of EOF" {
  @async.with_task_group(group => {
    let pty = @pty.spawn(group, ["/bin/cat"])
    defer pty.close()
    let reader = pty.reader()
    let buf : FixedArray[Byte] = FixedArray::make(64, b'\x00')
    let result = try? @async.with_timeout(100, () => reader.read(buf))
    debug_inspect(result, content="Err(TimeoutError)")
  })
}

///|
/// Spawn a program with a multi-argument argv and verify the args were
/// actually forwarded to the child. Uses `sh -c 'echo ARGV_OK'` because
/// that proves the child received at least two args and interpreted the
/// second one as a command.
#cfg(not(platform="windows"))
async test "spawn forwards argv beyond argv[0]" {
  @async.with_task_group(group => {
    let pty = @pty.spawn(group, ["/bin/sh", "-c", "echo ARGV_OK"])
    defer pty.close()
    assert_true(read_until_contains(pty, "ARGV_OK") is Some(_))
  })
}

///|
/// Spawn a program by bare name (not absolute path). This exercises the
/// PATH lookup we're adding — `execvp` must resolve `sh` via $PATH.
#cfg(not(platform="windows"))
async test "spawn resolves program via PATH" {
  @async.with_task_group(group => {
    let pty = @pty.spawn(group, ["sh", "-c", "echo PATH_OK"])
    defer pty.close()
    assert_true(read_until_contains(pty, "PATH_OK") is Some(_))
  })
}

///|
#cfg(not(platform="windows"))
async test "resize works after spawn" {
  @async.with_task_group(group => {
    let pty = @pty.spawn(group, ["/bin/sh"], cols=100, rows=30)
    defer pty.close()
    pty.resize(cols=101, rows=31)
    pty.write(@utf8.encode("stty size\nexit\n"))
    assert_true(read_until_contains(pty, "31 101", max_reads=16) is Some(_))
  })
}

///|
#cfg(not(platform="windows"))
async test "wait returns child exit code" {
  @async.with_task_group(group => {
    let pty = @pty.spawn(group, ["sh", "-c", "exit 7"])
    defer pty.close()
    debug_inspect(pty.wait(), content="7")
  })
}

///|
/// Spawning a program that doesn't exist must surface the exec failure
/// as an OSError, not silently return a live-looking Pty whose child
/// already died. Exercises the error-reporting pipe from the child
/// helper (macOS) / post-fork exec path (Linux).
#cfg(not(platform="windows"))
async test "spawn reports exec failure for missing program" {
  @async.with_task_group(group => {
    let err = try {
      let pty = @pty.spawn(group, ["/nonexistent/program/xyzzy"])
      pty.close()
      None
    } catch {
      e => Some(e)
    }
    debug_inspect(
      err,
      content=(
        #|Some(<moonbitlang/async/os_error.OSError.OSError: ...>)
      ),
    )
  })
}

///|
#cfg(platform="windows")
async test "cmd outputs through ConPTY" {
  @async.with_task_group(group => {
    let pty = @pty.spawn(group, ["cmd.exe", "/c", "echo", "WIN_READY"])
    defer pty.close()
    assert_true(pty.pid() > 0)
    assert_true(read_until_contains(pty, "WIN_READY") is Some(_))
    debug_inspect(pty.wait(), content="0")
  })
}

///|
#cfg(platform="windows")
async test "wait returns Windows child exit code" {
  @async.with_task_group(group => {
    let pty = @pty.spawn(group, ["cmd.exe", "/c", "exit", "7"])
    defer pty.close()
    debug_inspect(pty.wait(), content="7")
  })
}

///|
#cfg(platform="windows")
async test "Windows spawn preserves argv quoting" {
  @async.with_task_group(group => {
    let pty = @pty.spawn(group, [
      "powershell.exe", "-NoProfile", "-Command", "if ($args[0] -eq 'hello world' -and $args[1] -eq 'quote \" mark' -and $args[2] -eq '\"leading' -and $args[3] -eq '' -and $args[4] -eq '\"') { Write-Output 'WIN_ARGV_OK'; exit 0 } else { exit 1 }",
      "--", "hello world", "quote \" mark", "\"leading", "", "\"",
    ])
    defer pty.close()
    assert_true(read_until_contains(pty, "WIN_ARGV_OK") is Some(_))
  })
}
