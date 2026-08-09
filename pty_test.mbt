///|
#cfg(not(platform="windows"))
async test "@pty.spawn" {
  @async.with_task_group() <| g => {
    // `file` is looked up in PATH and becomes `argv[0]`; `args` is `argv[1..]`.
    let pty = @pty.spawn(g, "echo", ["hello"])
    assert_eq(pty.read_all().text(), "hello\r\n")
    assert_eq(pty.wait(), 0)
  }
}

///|
#cfg(not(platform="windows"))
async test "@pty.spawn passes file as argv[0]" {
  @async.with_task_group() <| g => {
    // `$0` in `sh -c` is the shell's own `argv[0]`, so this observes what the
    // child was actually handed rather than what we asked for.
    let pty = @pty.spawn(g, "sh", ["-c", "echo $0"])
    assert_eq(pty.read_all().text(), "sh\r\n")
    assert_eq(pty.wait(), 0)
  }
}

///|
#cfg(not(platform="windows"))
async test "@pty.spawn resolves an absolute file without searching PATH" {
  @async.with_task_group() <| g => {
    let pty = @pty.spawn(g, "/bin/sh", ["-c", "echo $0"])
    assert_eq(pty.read_all().text(), "/bin/sh\r\n")
    assert_eq(pty.wait(), 0)
  }
}

///|
#cfg(platform="windows")
async test "@pty.spawn (win32)" {
  @async.with_task_group() <| g => {
    let pty = @pty.spawn(g, "moon", ["version"], rows=24, cols=80)
    assert_true(pty.read_all().text().contains("moon"))
    assert_eq(pty.wait(), 0)
  }
}
