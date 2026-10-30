///|
// The wasm tests need a native sidecar executable: build one with
//
//   cc -O2 -Wall -o sidecar/sidecar sidecar/sidecar.c
//
// and run `moon test --target wasm` with `PTY_SIDECAR` pointing at it. Without
// one there is nothing to talk to, so every test below returns early instead
// of failing. `spawn` itself raises `ENOTSUP` in that case.
//
// This package is imported as `@wasm` (its directory name); downstream code
// can alias it to `@pty` in its own `moon.pkg`.
//
// These mirror the native tests in `pty_unix_test.mbt`, which stay the
// normative set for spawn semantics; the sidecar has to reproduce them.

///|
const ENOENT : Int32 = 2

///|
const EBADF : Int32 = 9

///|
fn has_sidecar() -> Bool {
  match @env.get_env_var(@wasm.SIDECAR_ENV) {
    Some(path) => path != ""
    None => false
  }
}

///|
async test "spawn" {
  guard has_sidecar() else {
    println("skipped: \{@wasm.SIDECAR_ENV} is not set")
    return
  }
  @async.with_task_group() <| g => {
    // `file` is looked up in PATH and becomes `argv[0]`; `args` is `argv[1..]`.
    let pty = @wasm.spawn(g, "echo", ["hello"])
    assert_eq(pty.read_all().text(), "hello\r\n")
    assert_eq(pty.wait(), 0)
  }
}

///|
async test "Pty::wait returns the child's exit code" {
  guard has_sidecar() else { return }
  @async.with_task_group() <| group => {
    let pty = @wasm.spawn(group, "sh", ["-c", "exit 7"])
    assert_eq(pty.wait(), 7)
  }
}

///|
async test "spawn passes file as argv[0]" {
  guard has_sidecar() else { return }
  @async.with_task_group() <| g => {
    // `$0` in `sh -c` is the shell's own `argv[0]`, so this observes what the
    // child was actually handed rather than what we asked for.
    let pty = @wasm.spawn(g, "sh", ["-c", "echo $0"])
    assert_eq(pty.read_all().text(), "sh\r\n")
    assert_eq(pty.wait(), 0)
  }
}

///|
async test "Pty::pid is the pid of the spawned child" {
  guard has_sidecar() else { return }
  @async.with_task_group() <| group => {
    // `$$` is the shell's own pid, which is the pid the sidecar reported.
    let pty = @wasm.spawn(group, "sh", ["-c", "echo $$"])
    assert_true(pty.pid() > 0)
    assert_eq(pty.read_all().text().trim().to_owned(), pty.pid().to_string())
    assert_eq(pty.wait(), 0)
  }
}

///|
async test "spawn applies rows/cols and resize updates the winsize" {
  guard has_sidecar() else { return }
  @async.with_task_group() <| group => {
    // Same shape as the native test: `stty size` reports "rows cols", `read`
    // holds the child until the resize below has happened, so the two reports
    // are strictly ordered. `-echo` keeps the newline we write out of the
    // output stream, and the first report is exactly 8 bytes for read_exactly.
    let pty = @wasm.spawn(
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
async test "spawn writes input through to the child's terminal" {
  guard has_sidecar() else { return }
  @async.with_task_group() <| group => {
    // `cat` echoes what it reads; ^D at line start ends canonical input, so
    // the child exits on its own and the read loop sees EOF.
    let pty = @wasm.spawn(group, "cat", [])
    pty.write("hello\r\n")
    assert_eq(pty.read_exactly(7), b"hello\r\n")
    pty.write(b"\x04")
    assert_eq(pty.wait(), 0)
  }
}

///|
async test "with_pty" {
  guard has_sidecar() else { return }
  @wasm.with_pty("echo", ["via with_pty"]) <| pty => {
    assert_eq(pty.read_all().text(), "via with_pty\r\n")
    assert_eq(pty.wait(), 0)
  }
}

///|
async test "spawn cancellation kills a running program" {
  guard has_sidecar() else { return }
  // `spawn` returns within a few milliseconds, so the 200 ms timer reliably
  // fires while the child is still running and the group is blocked on its
  // wait task. The test finishing at all is the real assertion: cancellation
  // must kill the child, or the group would wait on it for 3600 seconds.
  assert_eq(
    @async.with_timeout_opt(200) <| () => {
      @async.with_task_group() <| group => {
        @wasm.spawn(group, "sleep", ["3600"]) |> ignore()
      }
    },
    None,
  )
}

///|
async test "spawn(no_wait=true) lets the group exit without waiting" {
  guard has_sidecar() else { return }
  // Same `no_wait` semantics as `@async/process.spawn`: the group exits as
  // soon as its own body is done, cancelling the wait task, which kills the
  // child.
  let completed = @async.with_timeout_opt(15000) <| () => {
    @async.with_task_group() <| group => {
      @wasm.spawn(group, "sleep", ["3600"], no_wait=true) |> ignore()
    }
  }
  assert_true(completed is Some(_))
}

///|
async test "spawn raises ENOENT for a non-existent program" {
  guard has_sidecar() else { return }
  // The sidecar reports the child's `execve` errno back as an ERROR frame,
  // together with its own message; both have to survive the trip.
  @async.with_task_group() <| group => {
    try @wasm.spawn(group, "./non-existent", []) catch {
      @os_error.OSError(ENOENT, context~) =>
        assert_true(context.contains("spawn failed"))
      error => raise error
    } noraise {
      _ => fail("expected spawn(\"./non-existent\") to raise ENOENT")
    }
  }
}

///|
async test "Pty::resize raises EBADF after the group closed the pty" {
  guard has_sidecar() else { return }
  let mut pty : @wasm.Pty? = None
  @async.with_task_group() <| group => {
    pty = Some(@wasm.spawn(group, "true", []))
  }
  guard pty is Some(pty) else { fail("pty was not spawned") }
  try pty.resize(rows=10, cols=10) catch {
    @os_error.OSError(EBADF, ..) => ()
    error => raise error
  } noraise {
    _ => fail("expected resize on a closed pty to raise EBADF")
  }
}
