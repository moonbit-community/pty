///|
#cfg(not(platform="windows"))
struct Pty {
  closed : Ref[Bool]
  primary : @async/raw_fd.RawFdStream
  pid : Int
  result : @async.Task[Int]
}

///|
#cfg(not(platform="windows"))
#borrow(pty)
extern "c" fn pty_open(
  pty : FixedArray[@handle.Handle],
  rows~ : Int,
  cols~ : Int,
) -> Int = "moonbit_pty_open"

///|
#cfg(not(platform="windows"))
#borrow(pty, path, argv, envp, cwd)
extern "c" fn pty_spawn(
  pty : FixedArray[@handle.Handle],
  efd : @handle.Handle,
  path : FixedArray[Bytes],
  argv : FixedArray[Bytes],
  envp : FixedArray[Bytes],
  cwd : Bytes,
) -> Int = "moonbit_pty_spawn"

///|
#cfg(not(platform="windows"))
extern "c" fn pty_hard_cancel_group(pid : Int) -> Int = "moonbit_pty_hard_cancel_group"

///|
#cfg(not(platform="windows"))
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
  let pty : FixedArray[@handle.Handle] = [0, 0]
  if pty_open(pty, rows~, cols~) < 0 {
    raise @os_error.OSError(@os_error.get_errno(), context="@pty.spawn")
  }
  let pfd = pty[0]
  let replica = pty[1]
  let primary = @async/raw_fd.RawFdStream::RawFdStream(pfd.0) catch {
    error => {
      replica.close()
      raise error
    }
  }
  let env = if inherit_env { @env.get_env_vars() } else { Map([]) }
  for k, v in extra_env {
    env[k] = v
  }
  let path = get_path_candidates(
    file~,
    path=env.get_or_default("PATH", "/usr/bin:/bin"),
  )
  // `argv[0]` is `file` verbatim, not the path `resolve_path` picked. This is
  // what `execvp` (hence moonbitlang/async's `posix_spawnp`) does, and programs
  // that dispatch on `argv[0]` — busybox-style multi-call binaries, shells
  // checking for a leading `-` — need to see what the caller wrote.
  let argv = FixedArray::makei(args.length() + 1, i => {
    if i == 0 {
      @encoding/utf8.encode(file)
    } else {
      @encoding/utf8.encode(args[i - 1])
    }
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
  fn close_primary() {
    if !closed.val {
      primary.close()
      closed.val = true
    }
  }
  let result = group.spawn() <| () => {
    @async/process.wait_pid(pid) catch {
      _ if @async.is_being_cancelled() =>
        @async.protect_from_cancel() <| () => {
          @async.with_task_group() <| g => {
            g.spawn_bg(no_wait=true) <| () => {
              close_primary()
              @async.sleep(1000)
              pty_hard_cancel_group(pid) |> ignore()
            }
            @async/process.wait_pid(pid)
          }
        }
      error => raise error
    }
  }
  group.add_defer() <| () => { close_primary() }
  { closed, primary, pid, result }
}

///|
#cfg(not(platform="windows"))
pub async fn Pty::wait(self : Pty) -> Int {
  return self.result.wait()
}

///|
#cfg(not(platform="windows"))
pub fn Pty::pid(self : Pty) -> Int {
  self.pid
}

///|
#cfg(not(platform="windows"))
#warnings("-alert_internal")
pub impl @async/io.Reader for Pty with fn _get_internal_buffer(self : Pty) -> @async/io.ReaderBuffer {
  self.primary._get_internal_buffer()
}

///|
#cfg(not(platform="windows"))
const EIO : Int = 5

///|
#cfg(not(platform="windows"))
pub impl @async/io.Reader for Pty with fn _direct_read(
  self : Pty,
  buf : FixedArray[Byte],
  offset~ : Int,
  max_len~ : Int,
) -> Int {
  self.primary._direct_read(buf, offset~, max_len~) catch {
    @os_error.OSError(EIO, ..) => 0
    error => raise error
  }
}

///|
#cfg(not(platform="windows"))
pub impl @async/io.Writer for Pty with fn write_once(
  self : Pty,
  buf : Bytes,
  offset~ : Int,
  len~ : Int,
) -> Int {
  self.primary.write_once(buf, offset~, len~)
}

///|
#cfg(not(platform="windows"))
extern "c" fn pty_resize(
  primary : @handle.Handle,
  rows~ : Int,
  cols~ : Int,
) -> Int = "moonbit_pty_resize"

///|
#cfg(not(platform="windows"))
const EBADF : Int = 9

///|
#cfg(not(platform="windows"))
pub fn Pty::resize(
  self : Pty,
  rows~ : Int,
  cols~ : Int,
) -> Unit raise @os_error.OSError {
  if self.closed.val {
    raise @os_error.OSError(EBADF, context="@pty.Pty::resize")
  }
  if pty_resize(self.primary.fd, rows~, cols~) != 0 {
    raise @os_error.OSError(@os_error.get_errno(), context="@pty.Pty::resize")
  }
}

///|
#cfg(not(platform="windows"))
fn get_path_candidates(
  file~ : StringView,
  path~ : StringView,
) -> FixedArray[Bytes] {
  if file.contains_char('/') {
    return [@encoding/utf8.encode(file)]
  }
  let view = path.view()
  let candidates = []
  for p = view, dirp = view {
    match p {
      ([] as rest) | [':', .. rest] => {
        let dir = path[dirp.start_offset():p.start_offset()]
        let absolute = if dir is [] {
          @encoding/utf8.encode(file)
        } else {
          @encoding/utf8.encode("\{dir}/\{file}")
        }
        candidates.push(absolute)
        if rest is [] {
          break FixedArray::from_array(candidates)
        } else {
          continue rest, rest
        }
      }
      [_, .. rest] => continue rest, dirp
    }
  }
}

///|
#cfg(not(platform="windows"))
test "get_path_candidates" {
  assert_eq(get_path_candidates(file="sh", path="/usr/bin:/bin"), [
    b"/usr/bin/sh", b"/bin/sh",
  ])
  assert_eq(get_path_candidates(file="/usr/bin/sh", path="/bin:/usr/bin"), [
    b"/usr/bin/sh",
  ])
  assert_eq(get_path_candidates(file="./relative", path="/bin"), [b"./relative"])
  assert_eq(get_path_candidates(file="nosuchprog", path="/usr/bin:/bin"), [
    b"/usr/bin/nosuchprog", b"/bin/nosuchprog",
  ])
}
