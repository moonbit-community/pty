///|
// Unix-only behavior tests. Executable fixtures are generated at test time
// under a tmpdir (or taken from PATH), so no platform-specific binaries need
// to be committed.

///|
#cfg(not(platform="windows"))
const ENOENT : Int = 2

///|
#cfg(not(platform="windows"))
const EACCES : Int = 13

///|
#cfg(not(platform="windows"))
async test "@pty.spawn resolves a relative file against cwd" {
  @async.with_task_group() <| group => {
    with_tmpdir(prefix="moonbit-pty-relative") <| tmpdir => {
      @async/fs.write_file(
        "\{tmpdir}/echo.sh",
        b"#!/bin/sh\necho \"$@\"\n",
        create_mode=CreateNew,
        permission=0o755,
      )
      let pty = @pty.spawn(group, "./echo.sh", ["hello"], cwd=tmpdir)
      assert_eq(pty.read_all().text(), "hello\r\n")
      assert_eq(pty.wait(), 0)
    }
  }
}

///|
#cfg(not(platform="windows"))
async test "@pty.spawn cancellation kills a running program" {
  // `spawn` returns within a few milliseconds, so the 200ms timer reliably
  // fires while the child is still running and the group is blocked on its
  // wait task. The test finishing at all is the real assertion: cancellation
  // must kill the child, or the group would wait on it for 3600 seconds.
  assert_eq(
    @async.with_timeout_opt(200) <| () => {
      @async.with_task_group() <| group => {
        @pty.spawn(group, "sleep", ["3600"]) |> ignore()
      }
    },
    None,
  )
}

///|
#cfg(not(platform="windows"))
async test "@pty.spawn raises ENOENT for a non-existent program" {
  @async.with_task_group() <| group => {
    try @pty.spawn(group, "./non-existent", []) catch {
      @os_error.OSError(ENOENT, ..) => ()
      error => raise error
    } noraise {
      _ => fail("expected spawn(\"./non-existent\") to raise ENOENT")
    }
  }
}

///|
#cfg(not(platform="windows"))
async test "@pty.spawn raises EACCES for a file without execute permission" {
  @async.with_task_group() <| group => {
    with_tmpdir(prefix="moonbit-pty-noexec") <| tmpdir => {
      @async/fs.write_file(
        "\{tmpdir}/prog",
        b"#!/bin/sh\n",
        create_mode=CreateNew,
        permission=0o644,
      )
      try @pty.spawn(group, "./prog", [], cwd=tmpdir) catch {
        @os_error.OSError(EACCES, ..) => ()
        error => raise error
      } noraise {
        _ => fail("expected spawn without execute permission to raise EACCES")
      }
    }
  }
}
