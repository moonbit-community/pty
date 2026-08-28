///|
// Unix-only behavior tests. Executable fixtures are generated at test time
// under a tmpdir (or taken from PATH), so no platform-specific binaries need
// to be committed.

///|
// Shared with the win32 tests (same blackbox test package), so no #cfg.
async fn[T] with_tmpdir(prefix~ : StringView, f : async (String) -> T) -> T {
  let tmpdir = @async/fs.tmpdir(prefix~)
  async fn remove_tmpdir() {
    @async.protect_from_cancel() <| () => {
      @async/fs.rmdir(tmpdir, recursive=true) catch {
        _ => ()
      }
    }
  }
  defer remove_tmpdir()
  f(tmpdir)
}

///|
#cfg(not(platform="windows"))
const ENOENT : Int = 2

///|
#cfg(not(platform="windows"))
const EACCES : Int = 13

///|
#cfg(not(platform="windows"))
const EBADF : Int = 9

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
async test "@pty.Pty::wait returns the child's exit code" {
  @async.with_task_group() <| group => {
    let pty = @pty.spawn(group, "sh", ["-c", "exit 7"])
    assert_eq(pty.wait(), 7)
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
#cfg(not(platform="windows"))
async test "@pty.spawn(cwd~)" {
  @async.with_task_group() <| group => {
    with_tmpdir(prefix="moonbit-pty-spawn-cwd") <| tmpdir => {
      let pty = @pty.spawn(
        group,
        "/bin/sh",
        ["-c", "pwd"],
        rows=24,
        cols=80,
        cwd=tmpdir,
      )
      assert_true(pty.read_all().text().contains(tmpdir))
    }
  }
}

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
async test "@pty.spawn handles unicode paths and argv" {
  @async.with_task_group() <| group => {
    with_tmpdir(prefix="moonbit-pty-unicode") <| tmpdir => {
      // Unicode exercises the UTF-8 encoding of all three spawn inputs at
      // once: `cwd` (chdir), the resolved file (execve), and argv (echoed
      // back through the pty and decoded by `.text()`). CJK on purpose —
      // unaffected by macOS's NFD filename normalization, so the bytes
      // written are the bytes execve sees on every platform.
      let cwd = "\{tmpdir}/路径"
      @async/fs.mkdir(cwd)
      @async/fs.write_file(
        "\{cwd}/回声.sh",
        b"#!/bin/sh\necho \"$@\"\n",
        create_mode=CreateNew,
        permission=0o755,
      )
      let pty = @pty.spawn(group, "./回声.sh", ["你好"], cwd~)
      assert_eq(pty.read_all().text(), "你好\r\n")
      assert_eq(pty.wait(), 0)
    }
  }
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

///|
#cfg(not(platform="windows"))
async test "@pty.spawn applies rows/cols and resize updates the winsize" {
  @async.with_task_group() <| group => {
    // `stty size` reports the tty winsize as "rows cols"; `read` holds the
    // child until the resize below has happened, so the two reports are
    // strictly ordered. `-echo` keeps the newline we write out of the
    // output stream. The sizes are chosen to make the first report exactly
    // 8 bytes ("31 113\r\n") for read_exactly.
    let pty = @pty.spawn(
      group,
      "sh",
      ["-c", "stty -echo; stty size; read _; stty size"],
      rows=31,
      cols=113,
    )
    assert_eq(pty.read_exactly(8), b"31 113\r\n")
    pty.resize(rows=20, cols=100)
    pty.write("\n")
    assert_eq(pty.read_all().text(), "20 100\r\n")
    assert_eq(pty.wait(), 0)
  }
}

///|
#cfg(not(platform="windows"))
async test "@pty.Pty::resize raises EBADF after the group closed the pty" {
  let mut pty : @pty.Pty? = None
  @async.with_task_group() <| group => {
    pty = Some(@pty.spawn(group, "true", []))
  }
  guard pty is Some(pty) else { fail("pty was not spawned") }
  try pty.resize(rows=10, cols=10) catch {
    OSError(EBADF, ..) => ()
    error => raise error
  } noraise {
    _ => fail("expected resize on a closed pty to raise EBADF")
  }
}

///|
#cfg(not(platform="windows"))
async test "idle pty read waits instead of reporting EOF" {
  @async.with_task_group() <| group => {
    // `cat` is alive but silent: a read must suspend until data arrives,
    // never surface a spurious EOF — the `EIO => 0` mapping in
    // `_direct_read` sits right next to this behavior, and every consumer's
    // core loop is `while read() > 0`.
    let pty = @pty.spawn(group, "cat", [])
    assert_eq(@async.with_timeout_opt(100, () => pty.read_some()), None)
    // ^D at line start: canonical mode delivers EOF, cat exits on its own.
    pty.write(b"\x04")
    assert_eq(pty.wait(), 0)
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
async test "@pty.spawn(no_wait=true) lets the group exit without waiting" {
  // Same `no_wait` semantics as `@async/process.spawn`: the group exits as
  // soon as its own body is done, cancelling the wait task, which kills the
  // child. Completing inside the timeout (instead of blocking on `sleep` for
  // 3600 seconds until the timeout cancels everything) is the assertion.
  let completed = @async.with_timeout_opt(2000) <| () => {
    @async.with_task_group() <| group => {
      @pty.spawn(group, "sleep", ["3600"], no_wait=true) |> ignore()
    }
  }
  assert_true(completed is Some(_))
}

///|
#cfg(not(platform="windows"))
async test "@pty.Pty::pid is the pid of the spawned child" {
  @async.with_task_group() <| group => {
    // `$$` is the shell's own pid, which is the pid fork returned by spawn;
    // the string comparison also proves pid() is a real positive value.
    let pty = @pty.spawn(group, "sh", ["-c", "echo $$"])
    assert_true(pty.pid() > 0)
    assert_eq(pty.read_all().text().trim().to_owned(), pty.pid().to_string())
    assert_eq(pty.wait(), 0)
  }
}

///|
#cfg(not(platform="windows"))
async test "@pty.spawn(extra_env~) merges over the inherited environment" {
  // Variables only this test process exports, so the child's view is fully
  // determined here: one is inherited untouched, one is overridden by
  // extra_env, one exists only in extra_env.
  @env.set_env_var("MOONBIT_PTY_TEST_INHERITED", "parent")
  @env.set_env_var("MOONBIT_PTY_TEST_OVERRIDDEN", "parent")
  defer {
    @env.unset_env_var("MOONBIT_PTY_TEST_INHERITED")
    @env.unset_env_var("MOONBIT_PTY_TEST_OVERRIDDEN")
  }
  @async.with_task_group() <| group => {
    let pty = @pty.spawn(
      group,
      "sh",
      [
        "-c", "echo \"$MOONBIT_PTY_TEST_INHERITED $MOONBIT_PTY_TEST_OVERRIDDEN $MOONBIT_PTY_TEST_NEW\"",
      ],
      extra_env=Map([
        ("MOONBIT_PTY_TEST_OVERRIDDEN", "child"),
        ("MOONBIT_PTY_TEST_NEW", "new"),
      ]),
    )
    assert_eq(pty.read_all().text(), "parent child new\r\n")
    assert_eq(pty.wait(), 0)
  }
}

///|
#cfg(not(platform="windows"))
async test "@pty.spawn(inherit_env=false) starts the child with an empty environment" {
  // The child not seeing a variable this process exports proves nothing was
  // inherited, without depending on which variables sh leaves alone when
  // they are missing (zsh, for one, synthesizes HOME from passwd). `sh` is
  // deliberately relative: with no PATH in the environment, spawn falls back
  // to "/usr/bin:/bin" to resolve it.
  @env.set_env_var("MOONBIT_PTY_TEST_DROPPED", "parent")
  defer @env.unset_env_var("MOONBIT_PTY_TEST_DROPPED")
  @async.with_task_group() <| group => {
    let pty = @pty.spawn(
      group,
      "sh",
      ["-c", "echo \"${MOONBIT_PTY_TEST_DROPPED-unset} $ONLY_EXTRA\""],
      inherit_env=false,
      extra_env=Map([("ONLY_EXTRA", "kept")]),
    )
    assert_eq(pty.read_all().text(), "unset kept\r\n")
    assert_eq(pty.wait(), 0)
  }
}
