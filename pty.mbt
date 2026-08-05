///|
/// Handle to a spawned PTY plus its event-loop registration.
///
/// On Unix the PTY master fd is used for both reading and writing, so
/// `read_io` and `write_io` are the same `RawFdStream` wrapper around the
/// same `IoHandle`. The two fields exist so that reader and writer code
/// paths can use intent-revealing names. On Windows they point at the
/// separate ConPTY input/output pipe HANDLEs.
struct Pty {
  handle : PtyHandle
  read_io : @raw_fd.RawFdStream
  write_io : @raw_fd.RawFdStream
  spawned : PtySpawn
  // `RawFdStream::close` cannot safely interrupt a synchronous Windows
  // `ReadFile` running in async's worker pool. Keep the stream alive while an
  // operation is pending; closing the ConPTY/PTY source makes that operation
  // finish naturally, after which the stream handle can be released here.
  mut active_reads : Int
  mut active_writes : Int
  mut closed : Bool
}

///|
#cfg(platform="windows")
priv struct PtySpawn(@async.Task[Int])

///|
#cfg(not(platform="windows"))
priv struct PtySpawn(@process.Process)

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
/// `EIO` is 5 on every Unix platform (this code path is never compiled on
/// Windows), reported when the child's error pipe carries a malformed payload.
#cfg(not(platform="windows"))
const EIO : Int = 5

///|
/// Decode the child's pre-exec error report from the error pipe.
///
/// An empty payload means exec succeeded: the pipe is CLOEXEC, so the parent
/// just sees EOF. Otherwise the child wrote its errno as a 4-byte
/// little-endian integer (see `moonbit_pty_report_error` in `pty_unix.c`).
#cfg(not(platform="windows"))
fn decode_child_error(
  data : Bytes,
  context : String,
) -> Unit raise @os_error.OSError {
  match data[:] {
    [] | [i32le(0)] => ()
    [i32le(code)] => raise @os_error.OSError(code, context~)
    _ => raise @os_error.OSError(EIO, context~)
  }
}

///|
/// `EINVAL` is 22 on every Unix platform (Linux, macOS, and the BSDs alike).
#cfg(not(platform="windows"))
const INVALID_ARGUMENT : Int = 22

///|
/// Win32 `ERROR_INVALID_PARAMETER`: on Windows `@os_error` codes are
/// `GetLastError()` values, not CRT errno.
#cfg(platform="windows")
const INVALID_ARGUMENT : Int = 87

///|
/// For validation failures found in MoonBit, where no native call has set a
/// fresh errno/GetLastError value to report through `check_pty_status`.
fn raise_invalid_argument(context : String) -> Unit raise @os_error.OSError {
  raise @os_error.OSError(INVALID_ARGUMENT, context~)
}

///|
/// Spawn a new PTY running the given program.
///
/// `argv[0]` is the program to execute (resolved via PATH by `execvp`),
/// and `argv[1..]` are its arguments.
///
/// `cwd` sets the child's initial working directory. When omitted, the child
/// inherits the parent's working directory.
///
/// `cols` and `rows` default to 80x24 if not specified.
///
/// Must be called from inside an async event-loop context — the PTY's
/// master fd is registered with the event loop on construction so that
/// reads and writes can suspend instead of blocking the thread.
///
/// Raises `@os_error.OSError` wrapping `errno` (Unix) or `GetLastError()`
/// (Windows) if the underlying syscall fails.
#as_free_fn
#deprecated("Use @pty.spawn directly")
pub async fn[X] Pty::spawn(
  group : @async.TaskGroup[X],
  argv : Array[String],
  cwd? : StringView,
  cols? : Int = 80,
  rows? : Int = 24,
  no_wait? : Bool,
) -> Pty {
  if argv.is_empty() {
    raise_invalid_argument("pty.spawn: empty argv")
  }
  if cwd is Some(cwd) && cwd.find("\u{0}") is Some(_) {
    raise_invalid_argument("pty.spawn: cwd contains NUL")
  }
  let spawn_payload = build_spawn_payload(argv)
  let handle = PtyHandle::new()
  let spawned = spawn_handle(
    group,
    handle,
    spawn_payload,
    cols,
    rows,
    cwd?,
    no_wait?,
  ) catch {
    err => {
      handle.close()
      raise err
    }
  }
  // Transfer fd ownership from the C PTY handle to `RawFdStream`.
  let read_io = @raw_fd.RawFdStream(handle.take_read_fd()) catch {
    err => {
      handle.close()
      raise err
    }
  }
  let write_io = register_write_io(handle, read_io)
  {
    handle,
    read_io,
    write_io,
    spawned,
    active_reads: 0,
    active_writes: 0,
    closed: false,
  }
}

///|
#cfg(platform="windows")
fn StringBuilder::write_windows_arg(
  builder : StringBuilder,
  arg : StringView,
) -> Unit {
  let need_quote = if arg.length() == 0 {
    true
  } else {
    for char in arg {
      if char is (' ' | '\t' | '"') {
        break true
      }
    } nobreak {
      false
    }
  }
  if !need_quote {
    builder.write_stringview(arg)
    return
  }

  let mut segment_start = 0
  let mut index = 0
  let mut trailing_backslash = 0
  fn flush(skip : Int) {
    if index > segment_start {
      builder.write_stringview(arg[segment_start:index - trailing_backslash])
      if trailing_backslash > 0 {
        builder.write_string(String::make(trailing_backslash * 2, '\\'))
      }
    }
    segment_start = index + skip
  }

  builder.write_char('"')
  while index < arg.length() {
    match arg.code_unit_at(index) {
      '"' => {
        flush(1)
        builder.write_string("\\\"")
        trailing_backslash = 0
      }
      '\\' => trailing_backslash += 1
      _ => trailing_backslash = 0
    }
    index += 1
  }
  flush(0)
  builder.write_char('"')
}

///|
#cfg(platform="windows")
fn build_spawn_payload(argv : Array[String]) -> String {
  let command_line = StringBuilder::new()
  for i, arg in argv {
    if i > 0 {
      command_line.write_char(' ')
    }
    command_line.write_windows_arg(arg[:])
  }
  command_line.to_string()
}

///|
#cfg(not(platform="windows"))
fn build_spawn_payload(argv : Array[String]) -> Bytes {
  // Flatten argv into a single null-separated byte buffer:
  //   "arg0\0arg1\0...argN\0"
  // The Unix helper walks the buffer by null byte, using the buffer's own
  // length to know when to stop.
  let buf = Buffer()
  for arg in argv {
    buf.write_bytes(@utf8.encode(arg[:]))
    buf.write_byte(b'\x00')
  }
  buf.contents()
}

///|
#cfg(platform="windows")
fn[X] spawn_handle(
  group : @async.TaskGroup[X],
  handle : PtyHandle,
  command_line : String,
  cols : Int,
  rows : Int,
  cwd? : StringView,
  no_wait? : Bool,
) -> PtySpawn raise @os_error.OSError {
  let cwd_string = cwd.map(view => view.to_owned()).unwrap_or("")
  check_pty_status(
    handle.spawn(command_line, cwd_string, cwd is Some(_), cols, rows),
    "pty.spawn",
  )
  let pid = handle.child_pid()
  if pid <= 0 {
    raise_invalid_argument("pty.spawn: child pid")
  }
  let wait_task = group.spawn(no_wait?, () => {
    @process.wait_pid(pid) catch {
      _ if @async.is_being_cancelled() =>
        @async.protect_from_cancel(() => {
          pty_kill_pid(pid)
          @process.wait_pid(pid)
        })
      err => raise err
    }
  })
  PtySpawn(wait_task)
}

///|
#cfg(not(platform="windows"))
async fn[X] spawn_handle(
  group : @async.TaskGroup[X],
  handle : PtyHandle,
  argv_flat : Bytes,
  cols : Int,
  rows : Int,
  cwd? : StringView,
  no_wait? : Bool,
) -> PtySpawn {
  check_pty_status(handle.open(cols, rows), "pty.spawn")
  let mut keep_handle = false
  defer (if !keep_handle { handle.close() })
  let (argv_read, argv_write) = @pipe.pipe()
  defer argv_read.close()
  defer argv_write.close()
  let (err_read, err_write) = @pipe.pipe()
  defer err_read.close()
  defer err_write.close()
  let (slave_read, slave_write) = @pipe.pipe()
  defer slave_read.close()
  defer slave_write.close()

  let bind_err = handle.bind_slave_to_fd(slave_write.fd())
  check_pty_status(bind_err, "pty.spawn: bind slave")

  let self_cmd = @utf8.decode_lossy(pty_self_executable())
  if self_cmd.is_empty() {
    raise_invalid_argument("pty.spawn: self executable")
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
    cwd?,
    no_wait?,
  )
  handle.set_child_pid(child.pid)

  argv_read.close()
  err_write.close()
  slave_read.close()
  slave_write.close()

  try argv_write.write(argv_flat) catch {
    err => {
      decode_child_error(err_read.read_all().binary(), "pty.spawn")
      raise err
    }
  } noraise {
    _ => {
      argv_write.close()
      decode_child_error(err_read.read_all().binary(), "pty.spawn")
      err_read.close()
    }
  }
  keep_handle = true
  PtySpawn(child)
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
  read_io : @raw_fd.RawFdStream,
) -> @raw_fd.RawFdStream {
  read_io
}

///|
/// On Windows ConPTY has a separate input pipe HANDLE.
#cfg(platform="windows")
async fn register_write_io(
  handle : PtyHandle,
  read_io : @raw_fd.RawFdStream,
) -> @raw_fd.RawFdStream {
  @raw_fd.RawFdStream(handle.take_write_fd()) catch {
    err => {
      read_io.close()
      handle.close()
      raise err
    }
  }
}

///|
/// Release streams whose in-flight operations have finished after the PTY was
/// closed. POSIX uses one fd for both directions, so neither side can release
/// it while the other side is still using it.
#cfg(not(platform="windows"))
fn Pty::close_idle_streams(self : Pty) -> Unit {
  if self.closed && self.active_reads == 0 && self.active_writes == 0 {
    self.read_io.close()
  }
}

///|
/// Release Windows' separate ConPTY input/output handles independently once
/// their corresponding operation has finished.
#cfg(platform="windows")
fn Pty::close_idle_streams(self : Pty) -> Unit {
  if self.closed && self.active_reads == 0 {
    self.read_io.close()
  }
  if self.closed && self.active_writes == 0 {
    self.write_io.close()
  }
}

///|
/// Read once from the POSIX PTY master. Linux reports `EIO` instead of a
/// zero-length read when the slave closes; after `Pty::close` that condition is
/// the PTY's EOF, not a reader-task failure.
#cfg(not(platform="windows"))
async fn Pty::read_from_stream(
  self : Pty,
  buf : FixedArray[Byte],
  offset~ : Int,
  max_len~ : Int,
) -> Int {
  self.read_io.read(buf, offset~, max_len~) catch {
    @os_error.OSError(code, ..) if self.closed && code == EIO => 0
    err => raise err
  }
}

///|
#cfg(platform="windows")
async fn Pty::read_from_stream(
  self : Pty,
  buf : FixedArray[Byte],
  offset~ : Int,
  max_len~ : Int,
) -> Int {
  self.read_io.read(buf, offset~, max_len~)
}

///|
/// `Pty` owns its reader implementation so `close()` can coordinate the raw
/// stream lifetime without cancelling the task currently reading from it.
pub impl @io.Reader for Pty with fn _get_internal_buffer(self) {
  self.read_io._get_internal_buffer()
}

///|
pub impl @io.Reader for Pty with fn _direct_read(self, buf, offset~, max_len~) {
  if self.closed {
    return 0
  }
  self.active_reads += 1
  defer {
    self.active_reads -= 1
    self.close_idle_streams()
  }
  self.read_from_stream(buf, offset~, max_len~)
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
  if self.closed {
    raise_invalid_argument("Pty::write: closed")
  }
  self.active_writes += 1
  defer {
    self.active_writes -= 1
    self.close_idle_streams()
  }
  self.write_io.write(data)
}

///|
/// Resize the PTY window.
///
/// Raises `@os_error.OSError` if the underlying syscall fails.
pub fn Pty::resize(
  self : Pty,
  cols~ : Int,
  rows~ : Int,
) -> Unit raise @os_error.OSError {
  check_pty_status(self.handle.resize(cols, rows), "Pty::resize")
}

///|
/// Get the spawned child PID when available.
pub fn Pty::pid(self : Pty) -> Int {
  self.handle.child_pid()
}

///|
/// Wait for the spawned child process to exit and return its exit code.
///
/// This is backed by `moonbitlang/async/process`, so waiting/reaping lives
/// in the async process layer rather than in `Pty::close`.
#cfg(not(platform="windows"))
pub async fn Pty::wait(self : Pty) -> Int {
  let PtySpawn(process) = self.spawned
  process.wait()
}

///|
/// Wait for the spawned child process to exit and return its exit code.
///
/// This is backed by `moonbitlang/async/process`, so waiting/reaping lives
/// in the async process layer rather than in `Pty::close`.
#cfg(platform="windows")
pub async fn Pty::wait(self : Pty) -> Int {
  let PtySpawn(task) = self.spawned
  task.wait()
}

///|
/// Request cancellation of the child process.
#cfg(not(platform="windows"))
pub fn Pty::cancel(self : Pty) -> Unit {
  let PtySpawn(process) = self.spawned
  process.cancel()
}

///|
/// Request cancellation of the child process.
#cfg(platform="windows")
pub fn Pty::cancel(self : Pty) -> Unit {
  let pid = self.handle.child_pid()
  if pid > 0 {
    pty_kill_pid(pid)
  }
}

///|
/// Close the PTY, releasing all resources.
///
/// Stops the child so a pending read observes EOF before its `RawFdStream`
/// handle is released. An idle stream is released immediately; an in-flight
/// operation releases it after returning.
///
/// Resource lifetime is explicit: call this when the PTY is no longer needed.
/// The native handle is plain GC-managed memory with no finalizer, so OS
/// resources are never released by collection.
///
/// Safe to call multiple times because the underlying close paths are
/// idempotent.
#cfg(not(platform="windows"))
pub fn Pty::close(self : Pty) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.cancel()
  // Close the shared master immediately only when no read/write is using it.
  // Otherwise child shutdown closes the slave side, making the pending
  // operation finish before its defer releases the master.
  self.close_idle_streams()
  self.handle.close()
  self.close_idle_streams()
}

///|
/// Close the PTY, releasing all resources.
///
/// Stops the child so a pending read observes EOF before its `RawFdStream`
/// handle is released. Idle streams are released immediately; in-flight
/// operations release them after returning.
///
/// Resource lifetime is explicit: call this when the PTY is no longer needed.
/// The native handle is plain GC-managed memory with no finalizer, so OS
/// resources are never released by collection.
///
/// Safe to call multiple times because the underlying close paths are
/// idempotent.
#cfg(platform="windows")
pub fn Pty::close(self : Pty) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.cancel()
  // Close idle communication pipes before `ClosePseudoConsole`. A pending
  // output read stays open and drains shutdown output on async's worker thread.
  self.close_idle_streams()
  self.handle.close()
  self.close_idle_streams()
}
