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
extern "c" fn pty_unix_open(
  pty : FixedArray[@handle.Handle],
  rows~ : Int,
  cols~ : Int,
) -> Int = "moonbit_pty_unix_open"

///|
#cfg(not(platform="windows"))
#borrow(pty, efd, path, argv, envp, cwd)
extern "c" fn pty_unix_spawn(
  pty : FixedArray[@handle.Handle],
  efd : @handle.Handle,
  path : FixedArray[Bytes],
  argv : FixedArray[Bytes],
  envp : FixedArray[Bytes],
  cwd : Bytes,
) -> Int = "moonbit_pty_unix_spawn"

///|
#cfg(not(platform="windows"))
extern "c" fn pty_unix_kill_group(pid : Int) -> Int = "moonbit_pty_unix_kill_group"

///|
#cfg(not(platform="windows"))
#borrow(fds)
extern "c" fn pty_unix_create_error_pipe(
  fds : FixedArray[@handle.Handle],
) -> Int = "moonbit_pty_unix_create_error_pipe"

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
  no_wait? : Bool,
) -> Pty {
  let pty : FixedArray[@handle.Handle] = [
    @handle.Handle::invalid(),
    @handle.Handle::invalid(),
  ]
  if pty_unix_open(pty, rows~, cols~) < 0 {
    raise @os_error.OSError(@os_error.get_errno(), context="@pty.spawn")
  }
  let primary_handle = pty[0]
  let replica = pty[1]
  // `Handle::close` is a bare close(2): closing twice would hit whatever
  // unrelated fd has been handed the recycled number in between (the worker
  // pool and wait_pid allocate fds concurrently), so every close of the
  // replica is funneled through this guard.
  let mut replica_closed = false
  fn close_replica() {
    if !replica_closed {
      replica.close()
      replica_closed = true
    }
  }

  let primary = primary_handle.to_raw_fd_stream() catch {
    error => {
      close_replica()
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
  // defer off, so every failure below has to close both ends itself. The
  // replica is closed early on the success path, before the error-pipe read
  // can raise into the catch handler — `close_replica` keeps that from
  // becoming a double close.
  let pid = try {
    // The error pipe is a plain blocking pipe read through the worker thread
    // pool, NOT an async pipe: async pipes are registered with kqueue as
    // edge-triggered, and on macOS a pipe knote armed across a fork() can
    // lose its final EOF edge, hanging `read_all` below forever.
    let efds : FixedArray[@handle.Handle] = [
      @handle.Handle::invalid(),
      @handle.Handle::invalid(),
    ]
    if pty_unix_create_error_pipe(efds) < 0 {
      raise @os_error.OSError(@os_error.get_errno(), context="@pty.spawn")
    }
    let error_writer = efds[1]
    let error_reader = efds[0].to_raw_fd_stream() catch {
      error => {
        error_writer.close()
        raise error
      }
    }
    let pid = pty_unix_spawn(pty, error_writer, path, argv, envp, cwd)
    if pid < 0 {
      let errno = @os_error.get_errno()
      error_writer.close()
      error_reader.close()
      raise @os_error.OSError(errno, context="@pty.spawn")
    }
    error_writer.close()
    close_replica()
    defer error_reader.close()
    try error_reader.read_all().binary() catch {
      error => {
        pty_unix_kill_group(pid) |> ignore()
        @async.protect_from_cancel() <| () => {
          // The child was just SIGKILLed; no background work, the timeout is
          // only a safety net against a reap that never completes.
          ignore(
            @async.with_timeout_opt(1000, () => wait_pid_with(pid, () => ())),
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
      close_replica()
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
  let result = group.spawn(no_wait?) <| () => {
    @async/process.wait_pid(pid) catch {
      error if @async.is_being_cancelled() => {
        // Reap the child even though we are being cancelled, then propagate
        // the cancellation like `@async/process.spawn` does.
        let _ = @async.protect_from_cancel() <| () => {
          wait_pid_with(pid) <| () => {
            close_primary()
            // Grace period before the hard kill; keep in sync with the
            // win32 side (pty_win32.mbt), which is not type-checked here.
            @async.sleep(5000)
            pty_unix_kill_group(pid) |> ignore()
          }
        }
        raise error
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
#borrow(primary)
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
  if pty_resize(@handle.borrow_raw_fd_stream(self.primary), rows~, cols~) != 0 {
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
