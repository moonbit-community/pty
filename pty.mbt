///|
struct Pty {
  // Shared with the task spawned by `spawn`, which closes `primary` on
  // cancellation before the `Pty` value itself exists.
  closed : Ref[Bool]
  primary : @async/raw_fd.RawFdStream
  pid : Int
  result : @async.Task[Int]
}

///|
#borrow(pty)
extern "c" fn pty_open(pty : FixedArray[Int], rows~ : Int, cols~ : Int) -> Int = "moonbit_pty_open"

///|
extern "c" fn pty_close(fd : Int) -> Int = "close"

///|
#borrow(pty, path, argv, envp, cwd)
extern "c" fn pty_spawn(
  pty : FixedArray[Int],
  efd : Int,
  path : Bytes,
  argv : FixedArray[Bytes],
  envp : FixedArray[Bytes],
  cwd : Bytes,
) -> Int = "moonbit_pty_spawn"

///|
extern "c" fn pty_hard_cancel_group(pid : Int) -> Int = "moonbit_pty_hard_cancel_group"

///|
pub async fn[X] spawn(
  group : @async.TaskGroup[X],
  rows? : Int = 24,
  cols? : Int = 80,
  file : StringView,
  args : ArrayView[StringView],
  extra_env? : Map[String, String] = Map([]),
  inherit_env? : Bool = true,
  cwd? : StringView,
) -> Pty {
  let pty : FixedArray[Int] = [0, 0]
  if pty_open(pty, rows~, cols~) < 0 {
    raise @os_error.OSError(@os_error.get_errno(), context="@pty.spawn")
  }
  let pfd = pty[0]
  let rfd = pty[1]
  let primary = @async/raw_fd.RawFdStream::RawFdStream(pfd) catch {
    error => {
      pty_close(rfd) |> ignore()
      raise error
    }
  }
  let replica = @async/raw_fd.RawFdStream::RawFdStream(rfd) catch {
    error => {
      primary.close()
      raise error
    }
  }
  let env = if inherit_env { @env.get_env_vars() } else { Map([]) }
  for k, v in extra_env {
    env[k] = v
  }
  let path = resolve_path(
    file~,
    path=env.get_or_default("PATH", "/usr/bin:/bin"),
    cwd?,
  )
  let argv = FixedArray::makei(args.length(), i => {
    @encoding/utf8.encode(args[i])
  })
  let envp = {
    let envp = []
    for k, v in env {
      envp.push("\{k}=\{v}")
    }
    FixedArray::makei(envp.length(), i => @encoding/utf8.encode(envp[i]))
  }
  let cwd = if cwd is Some(cwd) { @encoding/utf8.encode(cwd) } else { b"" }
  // The pty is owned by this function until a `Pty` exists to hang the group
  // defer off, so every failure below has to close both ends itself. `close` is
  // idempotent, hence the replica being closed early on the success path does
  // not conflict with the handler.
  let pid = try {
    let (er, ew) = @async/pipe.pipe()
    let pid = pty_spawn(pty, ew.fd(), path, argv, envp, cwd)
    if pid < 0 {
      let errno = @os_error.get_errno()
      ew.close()
      er.close()
      raise @os_error.OSError(errno, context="@pty.spawn")
    }
    ew.close()
    replica.close()
    defer er.close()
    try er.read_all().binary() catch {
      error => {
        pty_hard_cancel_group(pid) |> ignore()
        @async.protect_from_cancel() <| () => {
          ignore(
            @async.with_timeout_opt(1000, () => {
              @async/process.wait_pid(pid) |> ignore()
            }),
          )
        }
        raise error
      }
    } noraise {
      [i32le(errno)] => {
        @async/process.wait_pid(pid) |> ignore()
        raise @os_error.OSError(errno, context="@pty.spawn")
      }
      [] => ()
      _ => {
        @async/process.wait_pid(pid) |> ignore()
        raise @os_error.OSError(EIO, context="@pty.spawn")
      }
    }
    pid
  } catch {
    error => {
      primary.close()
      replica.close()
      raise error
    }
  }
  let closed = Ref(false)
  let result = group.spawn() <| () => {
    @async/process.wait_pid(pid) catch {
      _ if @async.is_being_cancelled() =>
        @async.protect_from_cancel() <| () => {
          @async.with_task_group() <| g => {
            g.spawn_bg(no_wait=true) <| () => {
              closed.val = true
              primary.close()
              @async.sleep(1000)
              pty_hard_cancel_group(pid) |> ignore()
            }
            @async/process.wait_pid(pid)
          }
        }
      error => raise error
    }
  }
  let pty = { closed, primary, pid, result }
  group.add_defer() <| () => { pty.close() }
  pty
}

///|
pub async fn Pty::wait(self : Pty) -> Int {
  return self.result.wait()
}

///|
pub fn Pty::close(self : Pty) -> Unit {
  self.closed.val = true
  self.primary.close()
}

///|
pub fn Pty::pid(self : Pty) -> Int {
  self.pid
}

///|
#warnings("-alert_internal")
pub impl @async/io.Reader for Pty with fn _get_internal_buffer(self : Pty) -> @async/io.ReaderBuffer {
  self.primary._get_internal_buffer()
}

///|
const EIO : Int = 5

///|
pub impl @async/io.Reader for Pty with fn _direct_read(
  self : Pty,
  buf : FixedArray[Byte],
  offset~ : Int,
  max_len~ : Int,
) -> Int {
  self.primary._direct_read(buf, offset~, max_len~) catch {
    @os_error.OSError(errno, ..) if self.closed.val && errno == EIO => 0
    error => raise error
  }
}

///|
pub impl @async/io.Writer for Pty with fn write_once(
  self : Pty,
  buf : Bytes,
  offset~ : Int,
  len~ : Int,
) -> Int {
  self.primary.write_once(buf, offset~, len~)
}

///|
extern "c" fn pty_resize(primary : Int, rows~ : Int, cols~ : Int) -> Int = "moonbit_pty_resize"

///|
pub fn Pty::resize(
  self : Pty,
  rows~ : Int,
  cols~ : Int,
) -> Unit raise @os_error.OSError {
  guard !self.closed.val else {
    raise @os_error.OSError(9, context="@pty.Pty::resize")
  }
  if pty_resize(self.primary.fd, rows~, cols~) != 0 {
    raise @os_error.OSError(@os_error.get_errno(), context="@pty.Pty::resize")
  }
}

///|
#borrow(path)
extern "c" fn pty_is_executable(path : Bytes) -> Int = "moonbit_pty_is_executable"

///|
fn resolve_path(
  file~ : StringView,
  path~ : StringView,
  cwd? : StringView,
) -> Bytes raise @os_error.OSError {
  if file.contains_char('/') {
    if !(file is ['/', ..]) && cwd is Some(cwd) {
      return @encoding/utf8.encode("\{cwd}/\{file}")
    } else {
      return @encoding/utf8.encode(file)
    }
  }
  let view = path.view()
  let mut os_error : @os_error.OSError? = None
  for p = view, dirp = view {
    match p {
      ([] as rest) | [':', .. rest] => {
        let dir = path[dirp.start_offset():p.start_offset()]
        let absolute = if dir is [] {
          @encoding/utf8.encode("\{cwd.unwrap_or(".")}/\{file}")
        } else if dir is ['/', ..] {
          @encoding/utf8.encode("\{dir}/\{file}")
        } else if cwd is Some(cwd) {
          @encoding/utf8.encode("\{cwd}/\{dir}/\{file}")
        } else {
          @encoding/utf8.encode("./\{dir}/\{file}")
        }
        if pty_is_executable(absolute) != 0 {
          return absolute
        } else if !(os_error is Some(os_error) && os_error.is_EACCES()) {
          os_error = Some(
            @os_error.OSError(@os_error.get_errno(), context="stat"),
          )
        }
        if rest is [] {
          if os_error is Some(os_error) {
            raise os_error
          } else {
            raise @os_error.OSError(2, context="stat")
          }
        } else {
          continue rest, rest
        }
      }
      [_, .. rest] => continue rest, dirp
    }
  }
}

///|
test "resolve_path" {
  assert_eq(resolve_path(file="sh", path="/usr/bin:/bin"), b"/bin/sh")
  assert_eq(resolve_path(file="sh", path="/bin:/usr/bin"), b"/bin/sh")
  assert_eq(
    resolve_path(file="/usr/bin/sh", path="/bin:/usr/bin"),
    b"/usr/bin/sh",
  )
  assert_eq(resolve_path(file="./relative", path="/bin"), b"./relative")
  assert_true(
    @test.expect_error(() => {
      resolve_path(file="nosuchprog", path="/usr/bin:/bin")
    }).is_ENOENT(),
  )
}
