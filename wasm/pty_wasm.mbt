///|
/// Environment variable naming the sidecar executable to run.
///
/// The sidecar is a small native program (`sidecar/sidecar.c`) that owns the
/// pty on behalf of this wasm process, because a wasm module cannot open a
/// pseudo-terminal by itself. Build one with
///
///     cc -O2 -Wall -o sidecar/sidecar sidecar/sidecar.c
///
/// and point `PTY_SIDECAR` at the resulting executable.
pub const SIDECAR_ENV : String = "PTY_SIDECAR"

///|
/// Protocol version spoken with `sidecar/sidecar.c`.
const PROTOCOL_VERSION : Int32 = 1

///|
const EBADF : Int32 = 9

///|
const EINVAL : Int32 = 22

///|
/// Largest SPAWN frame the sidecar accepts; it rejects anything above its own
/// command limit instead of parsing it.
const MAX_SPAWN : Int32 = 1 << 20

///|
/// A pseudo-terminal attached to a spawned child process.
///
/// This is the wasm backend: a native sidecar process owns the pty pair and
/// the child, and this handle talks to it over a pair of pipes. It offers the
/// same API as the native backends, so `@async/io.Reader`/`Writer`, `wait`,
/// `pid` and `resize` behave the same way.
///
/// The pty's resources are released when the task group passed to `spawn`
/// exits. If the group is cancelled, the child gets the same 5 s grace period
/// the native backends give, then a hard kill.
struct Pty {
  closer : Closer
  pid : Int32
  reader : @async/pipe.PipeRead
  result : @async.Task[Int32]
}

///|
/// The parts of a `Pty` shared with the tasks that drive the sidecar: closing
/// it means "no more commands, and EOF on the command pipe", which is what
/// tells the sidecar to hang up.
priv struct Closer {
  closed : Ref[Bool]
  commands : @aqueue.Queue[Bytes]
  to_child : @async/process.WriteToProcess
}

///|
/// Close the pty's command pipe. The sidecar hangs up the child, waits the
/// grace period, kills its process group, and exits. Safe to call twice.
fn Closer::close(self : Closer) -> Unit {
  if self.closed.val {
    return
  }
  self.closed.val = true
  self.commands.close()
  self.to_child.close()
}

///|
/// Spawns a child process attached to a new pseudo-terminal and returns the
/// `Pty` handle, backed by a sidecar process named by `PTY_SIDECAR`.
///
/// The child runs `file` with `args` as its arguments; its `argv[0]` is
/// `file` verbatim, so programs that dispatch on `argv[0]` (busybox-style
/// multi-call binaries, shells checking for a leading `-`) see what the
/// caller wrote. `file` is looked up through `PATH` when it does not contain
/// a path separator, and used directly otherwise.
///
/// * `rows` and `cols` set the initial terminal size in characters.
/// * `extra_env` adds or overrides environment variables; by default
///   (`inherit_env=true`) the child also inherits the current process's
///   environment.
/// * `cwd` sets the child's working directory; by default the child starts
///   in the current directory.
/// * `no_wait` has the same semantics as `@async/process.spawn`: by default
///   the task group waits for the child to terminate; with `no_wait=true`
///   the group exits as soon as its own tasks are done, terminating the
///   child.
///
/// Raises `@os_error.OSError` if no sidecar is configured
/// (`ENOTSUP`), if the sidecar cannot be started, or if the child cannot be
/// spawned inside it.
pub async fn[X] spawn(
  group : @async.TaskGroup[X],
  rows~ : Int32 = 24,
  cols~ : Int32 = 80,
  file : StringView,
  args : ArrayView[StringView],
  extra_env~ : Map[String, String] = Map([]),
  inherit_env~ : Bool = true,
  cwd? : StringView,
  no_wait? : Bool,
) -> Pty {
  let executable = sidecar_executable()
  let env = if inherit_env { @env.get_env_vars() } else { Map([]) }
  for k, v in extra_env {
    env[k] = v
  }
  let path = @path.get_path_candidates(
    file~,
    path=env.get_or_default("PATH", "/usr/bin:/bin"),
  )
  // `argv[0]` is `file` verbatim, as on the native backends.
  let argv = FixedArray::makei(args.length() + 1, i => {
    if i == 0 {
      file.to_owned()
    } else {
      args[i - 1].to_owned()
    }
  })
  let envp = {
    let entries = []
    for k, v in env {
      entries.push("\{k}=\{v}")
    }
    entries
  }
  let child_cwd = if cwd is Some(dir) { dir.to_owned() } else { "" }
  let request = encode_spawn(rows, cols, path, argv, envp, child_cwd)
  if request.length() > MAX_SPAWN {
    raise @os_error.OSError(
      EINVAL,
      context="@pty.spawn: a \{request.length()} byte spawn request exceeds the sidecar's \{MAX_SPAWN} byte limit",
    )
  }
  let (child_stdin, to_child) = @async/process.write_to_process()
  let (from_child, child_stdout) = {
    errdefer to_child.close()
    @async/process.read_from_process()
  }
  let sidecar_pid = {
    errdefer to_child.close()
    errdefer from_child.close()
    defer child_stdout.close()
    @async/process.spawn_orphan(
      executable,
      [],
      stdin=child_stdin,
      stdout=child_stdout,
    )
  }
  let conn = Connection::new(from_child, to_child)
  // The sidecar exists from here on: every failure path has to reap it. It
  // exits by itself once its command pipe closes.
  errdefer {
    to_child.close()
    from_child.close()
    @async.protect_from_cancel(() => reap(sidecar_pid))
  }
  conn.send(TAG_SPAWN, request)
  let pid = match conn.read_frame() {
    Some(Hello(version~, pid~)) => {
      guard version == PROTOCOL_VERSION else {
        raise ProtocolError("unsupported sidecar protocol version \{version}")
      }
      pid
    }
    Some(Error(errno~, message~)) =>
      raise @os_error.OSError(errno, context="@pty.spawn: \{message}")
    Some(_) => raise ProtocolError("sidecar did not start with a hello frame")
    None => raise ProtocolError("sidecar exited before saying hello")
  }
  let (reader, writer) = @async/pipe.pipe()
  let commands : @aqueue.Queue[Bytes] = @aqueue.Queue::Queue(
    kind=@aqueue.Unbounded,
  )
  let closer = { closed: Ref(false), commands, to_child, }
  let result = group.spawn(no_wait?) <| () => {
    pump(conn, writer, closer, sidecar_pid)
  }
  group.spawn_bg(no_wait?, allow_failure=true) <| () => {
    dispatch_commands(conn, closer)
  }
  let pty = { closer, pid, reader, result, }
  group.add_defer() <| () => { pty.close() }
  pty
}

///|
/// Release the pty: close the command pipe, which the sidecar answers by
/// hanging up, and the reader side of the in-memory pipe. A task still
/// blocked reading it is released by the pump's EOF rather than woken up.
fn Pty::close(self : Pty) -> Unit {
  self.closer.close()
  self.reader.close()
}

///|
/// The sidecar executable this process was told to run.
fn sidecar_executable() -> String raise @os_error.OSError {
  match @env.get_env_var(SIDECAR_ENV) {
    Some(path) if path != "" => path
    _ =>
      raise @os_error.OSError(
        @os_error.errno_ENOTSUP,
        context="@pty.spawn: no pty sidecar executable, set \{SIDECAR_ENV}",
      )
  }
}

///|
/// Waits for the child process to terminate and returns its exit code.
/// If the process was killed by a signal, the result is `-signal_number`
/// (the same convention as `@async/process.wait_pid`).
///
/// Do not wait first and read afterwards: a reader that stops draining the
/// pty blocks the sidecar's relay, and `wait` only completes once the child
/// has exited and its remaining output has been forwarded.
pub async fn Pty::wait(self : Pty) -> Int32 {
  self.result.wait()
}

///|
/// The process ID of the spawned child process.
pub fn Pty::pid(self : Pty) -> Int32 {
  self.pid
}

///|
/// Resizes the child's terminal, in characters.
///
/// The request is queued for the command pump, so it is ordered before any
/// `write` issued afterwards. Raises `@os_error.OSError` if the pty has
/// already been closed (for example after the owning task group exited).
pub fn Pty::resize(
  self : Pty,
  rows~ : Int32,
  cols~ : Int32,
) -> Unit raise @os_error.OSError {
  if self.closer.closed.val {
    raise OSError(EBADF, context="@pty.Pty::resize")
  }
  let payload = @buffer.Buffer(size_hint=8)
  payload.write_uint_le(rows.reinterpret_as_uint())
  payload.write_uint_le(cols.reinterpret_as_uint())
  let accepted = self.closer.commands.try_put(
    encode_frame(TAG_RESIZE, payload.to_bytes()),
  ) catch {
    _ => false
  }
  if !accepted {
    raise OSError(EBADF, context="@pty.Pty::resize")
  }
}

///|
pub impl @async/io.Writer for Pty with fn write_once(
  self : Pty,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  // One frame per call; the default `write` loops over the rest. Larger
  // writes are split in `write` by the returned length.
  let len = if len > MAX_WRITE { MAX_WRITE } else { len }
  let frame = encode_frame(TAG_WRITE, buf[offset:offset + len])
  self.closer.commands.put(frame) catch {
    _ => raise @os_error.OSError(EBADF, context="@pty.Pty::write")
  }
  len
}

///|
pub extend Pty with @async/io.Writer::{write_once, write, write_reader}

///|
#deprecated("internal")
#doc(hidden)
pub extend Pty with @async/io.Reader::{_direct_read, _get_internal_buffer}

///|
#warnings("-alert_internal")
pub impl @async/io.Reader for Pty with fn _get_internal_buffer(self : Pty) -> @async/io.ReaderBuffer {
  @async/io.Reader::_get_internal_buffer(self.reader)
}

///|
pub impl @async/io.Reader for Pty with fn _direct_read(
  self : Pty,
  buf : FixedArray[Byte],
  offset~ : Int32,
  max_len~ : Int32,
) -> Int32 {
  @async/io.Reader::_direct_read(self.reader, buf, offset~, max_len~)
}

///|
pub extend Pty with @async/io.Reader::{
  read,
  read_some,
  drop,
  read_all,
  read_until,
  read_exactly,
}

///|
/// The command pump: the only writer of the sidecar's command pipe. Commands
/// are queued (so `resize` can stay synchronous) and sent in order.
async fn dispatch_commands(conn : Connection, closer : Closer) -> Unit {
  for ;; {
    let frame = closer.commands.get() catch {
      _ => break // the pty was closed
    }
    conn.send_bytes(frame) catch {
      _ => {
        closer.close()
        break
      }
    }
  }
}

///|
/// The output pump: reads frames until the child exits, forwards its output to
/// the reader side of the in-memory pipe, and completes with the exit status.
/// A `Pty` reads the sidecar through this task only.
async fn pump(
  conn : Connection,
  out : @async/pipe.PipeWrite,
  closer : Closer,
  sidecar_pid : Int32,
) -> Int32 {
  defer out.close()
  // A relay that fails (a protocol error, or the sidecar dying without an exit
  // status) still has to hang up and reap, or the sidecar process leaks.
  errdefer {
    closer.close()
    @async.protect_from_cancel(() => reap(sidecar_pid))
  }
  let status = @async.handle_cancellation(() => relay(conn, out))
  match status {
    Some(status) => {
      // The child is gone: no command can reach it any more.
      closer.close()
      @async.protect_from_cancel(() => reap(sidecar_pid))
      status
    }
    None =>
      // Cancelled: hang up, let the sidecar run the grace period and the
      // kill, and report the status it ends up with. `catch` no longer
      // observes cancellation (async 0.22), so this is the only place the
      // cleanup can run.
      @async.protect_from_cancel(() => {
        closer.close()
        let status = drain_to_exit(conn)
        reap(sidecar_pid)
        status
      })
  }
}

///|
/// Forward output frames until the sidecar reports the child's exit status.
async fn relay(conn : Connection, out : @async/pipe.PipeWrite) -> Int32 {
  for ;; {
    match conn.read_frame() {
      Some(Output(bytes)) => out.write(bytes)
      Some(Exit(status~)) => return status
      Some(Error(errno~, message~)) =>
        raise @os_error.OSError(errno, context="@pty: \{message}")
      Some(Hello(..)) => ()
      None =>
        raise ProtocolError(
          "sidecar exited without reporting the child's exit status",
        )
    }
  }
}

///|
/// Discard output until the exit status arrives, `-1` if the sidecar died
/// first. Used after cancellation, where nobody reads the pty any more.
///
/// Draining is what lets the sidecar finish: it cannot exit while its event
/// pipe is full, and its own final flush gives up after the grace period, so
/// this loop ends once the sidecar exits. The byte budget only keeps a
/// flooding child from being relayed forever.
async fn drain_to_exit(conn : Connection) -> Int32 {
  let mut budget = 1 << 20
  for ;; {
    match conn.read_frame() {
      Some(Exit(status~)) => return status
      Some(Output(bytes)) => {
        budget -= bytes.length()
        if budget <= 0 {
          return -1
        }
      }
      Some(_) => ()
      None => return -1
    }
  }
}

///|
/// Reap the sidecar process. It exits on its own once its child is gone and
/// its command pipe is closed.
async fn reap(sidecar_pid : Int32) -> Unit {
  ignore(wait_pid_with(sidecar_pid, () => ()))
}

///|
// Wait for `pid` while `background` runs alongside. The waiter is a spawned
// task on purpose, never the main task of the group: if the runtime cancels
// the waiter directly, the group fails with
// `@async.WaitedTaskAlreadyCancelled` instead of aborting the whole process.
// Same shape and reason as `wait_pid_with` in pty.mbt; see
// docs/invariants.md.
async fn wait_pid_with(pid : Int32, background : async () -> Unit) -> Int32 {
  @async.with_task_group() <| g => {
    let waiter = g.spawn(() => @async/process.wait_pid(pid))
    g.spawn_bg(no_wait=true, background)
    waiter.wait()
  }
}

///|
/// Encode a SPAWN request: the child's pty size, its PATH candidates, argv,
/// environment block, and working directory.
fn encode_spawn(
  rows : Int32,
  cols : Int32,
  path : FixedArray[Bytes],
  argv : FixedArray[String],
  envp : Array[String],
  cwd : String,
) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  buf.write_uint_le(rows.reinterpret_as_uint())
  buf.write_uint_le(cols.reinterpret_as_uint())
  buf.write_uint_le(path.length().reinterpret_as_uint())
  for candidate in path {
    write_sized(buf, candidate)
  }
  buf.write_uint_le(argv.length().reinterpret_as_uint())
  for arg in argv {
    write_sized(buf, @encoding/utf8.encode(arg))
  }
  buf.write_uint_le(envp.length().reinterpret_as_uint())
  for entry in envp {
    write_sized(buf, @encoding/utf8.encode(entry))
  }
  write_sized(buf, @encoding/utf8.encode(cwd))
  buf.to_bytes()
}

///|
/// `u32le len` followed by the bytes.
fn write_sized(buf : @buffer.Buffer, bytes : BytesView) -> Unit {
  buf.write_uint_le(bytes.length().reinterpret_as_uint())
  buf.write_bytes(bytes)
}

///|
/// Spawns a child process attached to a new pseudo-terminal, runs `f` with
/// its `Pty`, and releases the pty when `f` is done.
///
/// The pty lives exactly as long as `f`. When `f` returns, raises, or is
/// cancelled, the terminal is closed; a child that is still running is hung
/// up, given the 5 s grace period, then killed, and `with_pty` only returns
/// once it has been reaped. Call `Pty::wait` inside `f` to let the child
/// finish on its own and to get its exit code.
///
/// `rows`, `cols`, `file`, `args`, `extra_env`, `inherit_env` and `cwd` are
/// those of `spawn`, with the same defaults.
pub async fn[T] with_pty(
  rows? : Int32,
  cols? : Int32,
  file : StringView,
  args : ArrayView[StringView],
  extra_env? : Map[String, String],
  inherit_env? : Bool,
  cwd? : StringView,
  f : async (Pty) -> T,
) -> T {
  // `no_wait=true`: once `f` is done nobody reads the terminal any more, so
  // waiting for the child could block forever on a full pty queue. The group
  // cancels the wait task instead, which runs the usual cancellation cleanup.
  @async.with_task_group() <| group => {
    f(
      spawn(
        group,
        rows?,
        cols?,
        file,
        args,
        extra_env?,
        inherit_env?,
        cwd?,
        no_wait=true,
      ),
    )
  }
}
