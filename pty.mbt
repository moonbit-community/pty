///|
/// Handle to a spawned PTY plus its event-loop registration.
///
/// On Unix the PTY master fd is used for both reading and writing, so
/// `read_io` and `write_io` are the same `RawFd` wrapper around the same
/// `IoHandle`. The two fields exist so that reader and writer code paths
/// can use intent-revealing names. On Windows they point at the separate
/// ConPTY input/output pipe HANDLEs.
struct Pty {
  handle : PtyHandle
  read_io : @raw_fd.RawFd
  write_io : @raw_fd.RawFd
  process : @process.Process?
  wait_task : @async.Task[Int]?
}

///|
priv struct PtySpawn {
  process : @process.Process?
  wait_task : @async.Task[Int]?
}

///|
fn raise_last_os_error(context : String) -> Unit raise @os_error.OSError {
  @os_error.check_errno(context)
  // Fallback for defensive callers that returned -1 without setting errno.
  raise @os_error.OSError(0, context~)
}

///|
fn check_pty_status(
  ret : Int,
  context : String,
) -> Unit raise @os_error.OSError {
  if ret < 0 {
    raise_last_os_error(context)
  }
}

///|
fn raise_invalid_argument(context : String) -> Unit raise @os_error.OSError {
  // This is for validation failures found in MoonBit before any native call
  // can set errno/GetLastError. The C shim installs the platform-specific
  // invalid-argument code, then we report it through the normal os_error path.
  check_pty_status(pty_set_invalid_argument(), context)
}

///|
/// Spawn a new PTY running the given program.
///
/// `argv[0]` is the program to execute (resolved via PATH by `execvp`),
/// and `argv[1..]` are its arguments.
///
/// `cols` and `rows` default to 80x24 if not specified.
///
/// Must be called from inside an async event-loop context — the PTY's
/// master fd is registered with the event loop on construction so that
/// reads and writes can suspend instead of blocking the thread.
///
/// Raises `@os_error.OSError` wrapping `errno` (Unix) or `GetLastError()`
/// (Windows) if the underlying syscall fails.
pub async fn[X] Pty::spawn(
  group : @async.TaskGroup[X],
  argv : Array[String],
  cols? : Int = 80,
  rows? : Int = 24,
  no_wait? : Bool,
) -> Pty {
  if argv.is_empty() {
    raise_invalid_argument("Pty::spawn: empty argv")
  }
  // Flatten argv into a single null-separated byte buffer:
  //   "arg0\0arg1\0...argN\0"
  // The C side walks the buffer by null byte, using the buffer's own
  // length to know when to stop.
  let buf = @buffer.new()
  for arg in argv {
    buf.write_bytes(@utf8.encode(arg[:]))
    buf.write_byte(b'\x00')
  }
  let argv_flat = buf.contents()
  let handle = pty_new()
  let spawned = spawn_handle(group, handle, argv_flat, cols, rows, no_wait?) catch {
    err => {
      pty_close(handle)
      raise err
    }
  }
  // Transfer fd ownership from the C PTY handle to `RawFd`.
  let read_io = @raw_fd.RawFd::RawFd(pty_take_read_fd(handle)) catch {
    err => {
      pty_close(handle)
      raise err
    }
  }
  let write_io = register_write_io(handle, read_io)
  {
    handle,
    read_io,
    write_io,
    process: spawned.process,
    wait_task: spawned.wait_task,
  }
}

///|
#cfg(platform="windows")
fn[X] spawn_handle(
  group : @async.TaskGroup[X],
  handle : PtyHandle,
  argv_flat : Bytes,
  cols : Int,
  rows : Int,
  no_wait? : Bool,
) -> PtySpawn raise @os_error.OSError {
  check_pty_status(
    pty_spawn_windows(handle, argv_flat, cols, rows),
    "Pty::spawn",
  )
  let pid = pty_child_pid(handle)
  if pid <= 0 {
    raise_invalid_argument("Pty::spawn: child pid")
  }
  let wait_task = group.spawn(no_wait?, () => {
    @process.wait_pid(pid) catch {
      _ if @async.is_being_cancelled() =>
        @async.protect_from_cancel(() => {
          pty_kill_pid_windows(pid)
          @process.wait_pid(pid)
        })
      err => raise err
    }
  })
  { process: None, wait_task: Some(wait_task) }
}

///|
#cfg(not(platform="windows"))
async fn[X] spawn_handle(
  group : @async.TaskGroup[X],
  handle : PtyHandle,
  argv_flat : Bytes,
  cols : Int,
  rows : Int,
  no_wait? : Bool,
) -> PtySpawn {
  spawn_handle_with_async_self(group, handle, argv_flat, cols, rows, no_wait?)
}

///|
#cfg(not(platform="windows"))
async fn[X] spawn_handle_with_async_self(
  group : @async.TaskGroup[X],
  handle : PtyHandle,
  argv_flat : Bytes,
  cols : Int,
  rows : Int,
  no_wait? : Bool,
) -> PtySpawn {
  check_pty_status(pty_open(handle, cols, rows), "Pty::spawn")
  let mut keep_handle = false
  defer (if !keep_handle { pty_close(handle) })
  let (argv_read, argv_write) = @pipe.pipe()
  defer argv_read.close()
  defer argv_write.close()
  let (err_read, err_write) = @pipe.pipe()
  defer err_read.close()
  defer err_write.close()
  let (slave_read, slave_write) = @pipe.pipe()
  defer slave_read.close()
  defer slave_write.close()

  let bind_err = pty_bind_slave_to_fd(handle, slave_write.fd())
  check_pty_status(bind_err, "Pty::spawn: bind slave")

  let self_cmd = @utf8.decode_lossy(pty_self_executable())
  if self_cmd.is_empty() {
    raise_invalid_argument("Pty::spawn: self executable")
  }
  let self_args = parse_self_args(pty_self_args_flat())

  let child = @process.spawn(
    group,
    self_cmd,
    self_args,
    stdin=argv_read,
    stdout=slave_write,
    stderr=err_write,
    extra_env={ "MOONBIT_PTY_EXEC": "stdio" },
    no_wait?,
  )
  pty_set_child_pid(handle, child.pid)

  argv_read.close()
  err_write.close()
  slave_read.close()
  slave_write.close()

  let argv_write_result = try? argv_write.write(argv_flat)
  argv_write.close()

  let child_err = pty_decode_child_error(err_read.read_all().binary())
  err_read.close()
  check_pty_status(child_err, "Pty::spawn")
  match argv_write_result {
    Ok(_) => ()
    Err(err) => raise err
  }
  keep_handle = true
  { process: Some(child), wait_task: None }
}

///|
#cfg(not(platform="windows"))
fn parse_self_args(flat : Bytes) -> Array[String] {
  let args : Array[String] = []
  let mut start = 0
  let mut index = 0
  for i in 0..<flat.length() {
    if flat[i] == b'\x00' {
      if index > 0 {
        args.push(@utf8.decode_lossy(flat[start:i]))
      }
      index += 1
      start = i + 1
    }
  }
  args
}

///|
/// On Unix read and write share the same PTY master fd.
#cfg(not(platform="windows"))
fn register_write_io(
  _handle : PtyHandle,
  read_io : @raw_fd.RawFd,
) -> @raw_fd.RawFd {
  read_io
}

///|
/// On Windows ConPTY has a separate input pipe HANDLE.
#cfg(platform="windows")
async fn register_write_io(
  handle : PtyHandle,
  read_io : @raw_fd.RawFd,
) -> @raw_fd.RawFd {
  @raw_fd.RawFd::RawFd(pty_take_write_fd_windows(handle)) catch {
    err => {
      read_io.close()
      pty_close(handle)
      raise err
    }
  }
}

///|
/// Get the async reader for this PTY.
///
/// The returned `RawFd` is owned by the `Pty`; do not call `close()`
/// or `detach()` on it. Use `Pty::close` to release the registration.
pub fn Pty::reader(self : Pty) -> @raw_fd.RawFd {
  self.read_io
}

///|
/// Write data to the PTY stdin.
///
/// Suspends the current coroutine via the async event loop until all
/// bytes are written, so a stuck child that stops draining its input
/// buffer won't block other concurrent tasks in the runtime.
///
/// Raises `@os_error.OSError` if the underlying write fails.
pub async fn Pty::write(self : Pty, data : Bytes) -> Unit {
  let total = data.length()
  let mut offset = 0
  while offset < total {
    let n = self.write_io.write(data, offset~, len=total - offset)
    if n <= 0 {
      raise_invalid_argument("Pty::write: short write")
    }
    offset += n
  }
}

///|
/// Resize the PTY window.
///
/// Raises `@os_error.OSError` if the underlying syscall fails.
pub fn Pty::resize(
  self : Pty,
  cols : Int,
  rows : Int,
) -> Unit raise @os_error.OSError {
  check_pty_status(pty_resize(self.handle, cols, rows), "Pty::resize")
}

///|
/// Get the spawned child PID when available.
pub fn Pty::pid(self : Pty) -> Int {
  pty_child_pid(self.handle)
}

///|
/// Wait for the spawned child process to exit and return its exit code.
///
/// This is backed by `moonbitlang/async/process`, so waiting/reaping lives
/// in the async process layer rather than in `Pty::close`.
pub async fn Pty::wait(self : Pty) -> Int {
  match self.process {
    Some(process) => process.wait()
    None =>
      match self.wait_task {
        Some(task) => task.wait()
        None => -1
      }
  }
}

///|
/// Request cancellation of the child process.
#cfg(not(platform="windows"))
pub fn Pty::cancel(self : Pty) -> Unit {
  match self.process {
    Some(process) => process.cancel()
    None => ()
  }
}

///|
/// Request cancellation of the child process.
#cfg(platform="windows")
pub fn Pty::cancel(self : Pty) -> Unit {
  let pid = pty_child_pid(self.handle)
  if pid > 0 {
    pty_kill_pid_windows(pid)
  }
}

///|
/// Close the PTY, releasing all resources.
///
/// Closes the owned `RawFd` wrapper(s) and then tears down the underlying
/// OS PTY handle.
///
/// Safe to call multiple times because the underlying close paths are
/// idempotent.
#cfg(not(platform="windows"))
pub fn Pty::close(self : Pty) -> Unit {
  self.cancel()
  self.read_io.close()
  pty_close(self.handle)
}

///|
/// Close the PTY, releasing all resources.
///
/// Closes the owned `RawFd` wrapper(s) and then tears down the underlying
/// OS PTY handle.
///
/// Safe to call multiple times because the underlying close paths are
/// idempotent.
#cfg(platform="windows")
pub fn Pty::close(self : Pty) -> Unit {
  self.cancel()
  self.read_io.close()
  self.write_io.close()
  pty_close(self.handle)
}
