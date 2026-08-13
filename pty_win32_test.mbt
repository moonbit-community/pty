///|
#cfg(platform="windows")
async test "@pty.spawn can spawn file.exe using file" {
  async fn assert_pty_spawn(file : StringView) {
    @async.with_task_group() <| group => {
      let text = "Hello, world!"
      let pty = @pty.spawn(group, rows=24, cols=80, file) <| [
        text,
      ]
      assert_true(pty.read_all().text().contains(text))
      assert_eq(pty.wait(), 0)
    }
  }
  assert_pty_spawn("test_data\\win32\\echo")
  assert_pty_spawn("test_data\\win32\\echo.exe")
}

///|
#cfg(platform="windows")
async test "@pty.spawn can spawn file.exe using cwd" {
  async fn assert_pty_spawn(file : StringView) {
    @async.with_task_group() <| group => {
      let text = "Hello, world!"
      let pty = @pty.spawn(
        group,
        rows=24,
        cols=80,
        file,
        cwd="test_data\\win32",
      ) <| [
        text,
      ]
      assert_true(pty.read_all().text().contains(text))
      assert_eq(pty.wait(), 0)
    }
  }
  assert_pty_spawn(".\\echo")
  assert_pty_spawn(".\\echo.exe")
}
