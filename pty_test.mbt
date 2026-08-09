///|
#cfg(not(platform="windows"))
async test "@pty.spawn" {
  @async.with_task_group() <| g => {
    let pty = @pty.spawn(g, "/bin/echo", ["echo", "hello"])
    assert_eq(pty.read_all().text(), "hello\r\n")
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
