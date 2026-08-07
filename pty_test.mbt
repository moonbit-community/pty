///|
async test "@pty.spawn" {
  @async.with_task_group() <| g => {
    let pty = @pty.spawn(g, "/bin/echo", ["echo", "hello"])
    assert_eq(pty.read_all().text(), "hello\r\n")
    assert_eq(pty.wait(), 0)
  }
}
