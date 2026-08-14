///|
#cfg(platform="windows")
const ERROR_FILE_NOT_FOUND : Int = 2

///|
// `CreateProcessW` refuses a file that resolves but is not a valid executable
// image. Which code it picks varies by Windows version/architecture: classic
// is ERROR_BAD_EXE_FORMAT (193); Windows 11 was observed returning
// ERROR_EXE_MACHINE_TYPE_MISMATCH (216) for the same text-file fixture.
#cfg(platform="windows")
const ERROR_BAD_EXE_FORMAT : Int = 193

///|
#cfg(platform="windows")
const ERROR_EXE_MACHINE_TYPE_MISMATCH : Int = 216

///|
// `Pty::resize` raises errno EBADF once the wait task has closed the HPCON.
#cfg(platform="windows")
const EBADF : Int = 9

///|
// The win32 analog of the unix "generate fixtures at test time" policy:
// instead of committing a compiled binary, copy the system cmd.exe
// (%ComSpec%) to `target`. Spawned with ["/c", "echo", text] it produces
// observable output regardless of the name it runs under. No cleanup of its
// own — `target` is expected to live in a `with_tmpdir` directory.
#cfg(platform="windows")
async fn with_comspec_copied(target : StringView, f : async () -> Unit) -> Unit {
  // `get_env_var` is `GetEnvironmentVariableW` on win32, which looks keys up
  // ordinal-ignore-case itself.
  let comspec = @env.get_env_var("ComSpec").unwrap_or(
    "C:\\Windows\\System32\\cmd.exe",
  )
  @async/fs.write_file(
    target,
    @async/fs.read_file(comspec),
    create_mode=CreateNew,
  )
  f()
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

///|
#cfg(platform="windows")
async test "@pty.spawn can spawn file.exe using file" {
  with_tmpdir(prefix="moonbit-pty-fixture") <| tmpdir => {
    with_comspec_copied("\{tmpdir}\\echo.exe") <| () => {
      async fn assert_pty_spawn(file : StringView) {
        @async.with_task_group() <| group => {
          let text = "Hello, world!"
          let pty = @pty.spawn(group, rows=24, cols=80, file) <| [
            "/c", "echo", text,
          ]
          assert_true(pty.read_all().text().contains(text))
          assert_eq(pty.wait(), 0)
        }
      }
      assert_pty_spawn("\{tmpdir}\\echo")
      assert_pty_spawn("\{tmpdir}\\echo.exe")
    }
  }
}

///|
#cfg(platform="windows")
async test "@pty.spawn can spawn file.exe using cwd" {
  with_tmpdir(prefix="moonbit-pty-fixture") <| tmpdir => {
    with_comspec_copied("\{tmpdir}\\echo.exe") <| () => {
      async fn assert_pty_spawn(file : StringView) {
        @async.with_task_group() <| group => {
          let text = "Hello, world!"
          let pty = @pty.spawn(group, rows=24, cols=80, file, cwd=tmpdir) <| [
            "/c", "echo", text,
          ]
          assert_true(pty.read_all().text().contains(text))
          assert_eq(pty.wait(), 0)
        }
      }
      assert_pty_spawn(".\\echo")
      assert_pty_spawn(".\\echo.exe")
    }
  }
}

///|
#cfg(platform="windows")
async test "@pty.Pty::wait returns the child's exit code (win32)" {
  @async.with_task_group() <| group => {
    let pty = @pty.spawn(group, "cmd", ["/c", "exit", "7"])
    assert_eq(pty.wait(), 7)
  }
}

///|
// Unicode in `cwd` and in the resolved executable path exercises the
// UTF-16 conversions behind GetFullPathNameW / the file-exists probe /
// CreateProcessW's lpApplicationName. The echoed text stays ASCII so the
// assertion is independent of cmd.exe's output codepage.
#cfg(platform="windows")
async test "@pty.spawn handles unicode paths (win32)" {
  @async.with_task_group() <| group => {
    with_tmpdir(prefix="moonbit-pty-unicode") <| tmpdir => {
      let cwd = "\{tmpdir}\\路径"
      @async/fs.mkdir(cwd)
      with_comspec_copied("\{cwd}\\回声.exe") <| () => {
        let text = "UNICODE_CWD_OK"
        let pty = @pty.spawn(group, ".\\回声", ["/c", "echo", text], cwd~)
        assert_true(pty.read_all().text().contains(text))
        assert_eq(pty.wait(), 0)
      }
    }
  }
}

///|
// The userland resolver raises before any handle exists, so this exercises
// the no-cleanup failure path.
#cfg(platform="windows")
async test "@pty.spawn raises ERROR_FILE_NOT_FOUND for a non-existent program" {
  @async.with_task_group() <| group => {
    try @pty.spawn(group, ".\\non-existent", []) catch {
      @os_error.OSError(ERROR_FILE_NOT_FOUND, ..) => ()
      error => raise error
    } noraise {
      _ =>
        fail(
          "expected spawn of a non-existent program to raise ERROR_FILE_NOT_FOUND",
        )
    }
  }
}

///|
// A text file named `foo.exe` resolves but cannot start, so this is the path
// that reaches the `pid < 0` cleanup branch (pipes + HPCON already exist and
// must each be closed exactly once). The follow-up spawn in the same group is
// the double-close detector: on unix the equivalent bug surfaced as EBADF in
// whatever ran next, because the recycled fd number got closed a second time.
#cfg(platform="windows")
async test "@pty.spawn raises ERROR_BAD_EXE_FORMAT for a non-executable .exe" {
  @async.with_task_group() <| group => {
    with_tmpdir(prefix="moonbit-pty-badexe") <| tmpdir => {
      @async/fs.write_file(
        "\{tmpdir}\\foo.exe",
        b"not an executable",
        create_mode=CreateNew,
      )
      try @pty.spawn(group, ".\\foo.exe", [], cwd=tmpdir) catch {
        @os_error.OSError(ERROR_BAD_EXE_FORMAT, ..)
        | @os_error.OSError(ERROR_EXE_MACHINE_TYPE_MISMATCH, ..) => ()
        error => raise error
      } noraise {
        _ =>
          fail(
            "expected spawn of a non-executable .exe to raise ERROR_BAD_EXE_FORMAT",
          )
      }
      let pty = @pty.spawn(group, "cmd", ["/c", "echo", "still works"])
      assert_true(pty.read_all().text().contains("still works"))
      assert_eq(pty.wait(), 0)
    }
  }
}

///|
#cfg(platform="windows")
async test "@pty.Pty::resize raises EBADF after the group closed the pty" {
  let mut pty : @pty.Pty? = None
  @async.with_task_group() <| group => {
    pty = Some(@pty.spawn(group, "cmd", ["/c", "echo", "bye"]))
  }
  guard pty is Some(pty) else { fail("pty was not spawned") }
  try pty.resize(rows=10, cols=10) catch {
    @os_error.OSError(EBADF, ..) => ()
    error => raise error
  } noraise {
    _ => fail("expected resize on a closed pty to raise EBADF")
  }
}
