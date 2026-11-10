///|
/// Bytes of terminal input that may be on their way to the sidecar at once.
/// `write_once` waits for WROTE acknowledgements beyond this, which is what
/// makes writing to a child that does not read block, as it would on a real
/// pty.
const WRITE_WINDOW : Int32 = 64 * 1024

///|
/// Largest WRITE payload sent in one frame.
const MAX_WRITE : Int32 = 32 * 1024

///|
/// The error code for operations on a pty that has been closed: EBADF on
/// Unix, and the value the library has always used on Windows.
const CLOSED_ERROR : Int32 = 9

///|
/// A running pty sidecar and the child it spawned on its terminal.
///
/// Events are not read by a task of their own: whoever needs one (a writer
/// waiting for room, a resize waiting for its reply, the wait for the exit)
/// becomes the reader while the others wait on `cond`. A background reader
/// could be cancelled while the cancellation cleanup still needs the child's
/// exit, and would read events nobody asked for into unbounded state.
struct Sidecar {
  pid : Int32
  mut child_pid : Int32
  commands : @async/process.WriteToProcess
  output : @async/process.ReadFromProcess
  events_pipe : @async/process.ReadFromProcess
  events : EventReader
  temp_dir : String?
  send_lock : @async.Mutex
  cond : @async/cond_var.Cond
  // A send failed part way: the sidecar now waits for the rest of that frame
  // and nothing sent later can be parsed.
  mut send_broken : Bool
  mut reading : Bool
  mut events_eof : Bool
  mut failure : Error?
  mut exit_status : Int32?
  mut in_flight : Int32
  mut write_error : Int32?
  mut resize_sent : Int32
  mut resize_seen : Int32
  // Sequence numbers of resizes still waiting for their reply.
  resize_waiting : Set[Int32]
  resize_results : Map[Int32, Int32]
  mut closed : Bool
  mut reaped : Bool
}

///|
/// Start a sidecar and have it spawn the child described by `request`.
/// Raises `@os_error.OSError` with the OS error code when the child cannot
/// be started.
pub async fn Sidecar::spawn(request : SpawnRequest) -> Sidecar {
  let (path, temp_dir) = locate()
  errdefer (if temp_dir is Some(dir) { remove_temp_dir(dir) })
  let (child_stdin, commands) = @async/process.write_to_process()
  let (output, child_stdout) = {
    errdefer commands.close()
    @async/process.read_from_process()
  }
  let (events_pipe, child_stderr) = {
    errdefer commands.close()
    errdefer output.close()
    errdefer child_stdout.close()
    @async/process.read_from_process()
  }
  let pid = {
    errdefer commands.close()
    errdefer output.close()
    errdefer events_pipe.close()
    defer child_stdout.close()
    defer child_stderr.close()
    @async/process.spawn_orphan(
      path,
      [],
      stdin=child_stdin,
      stdout=child_stdout,
      stderr=child_stderr,
      no_console_window=true,
    )
  }
  let sidecar = {
    pid,
    child_pid: -1,
    commands,
    output,
    events_pipe,
    events: EventReader::new(events_pipe),
    temp_dir,
    send_lock: @async.Mutex(),
    cond: @async/cond_var.Cond(),
    send_broken: false,
    reading: false,
    events_eof: false,
    failure: None,
    exit_status: None,
    in_flight: 0,
    write_error: None,
    resize_sent: 0,
    resize_seen: 0,
    resize_waiting: Set([]),
    resize_results: Map([]),
    closed: false,
    reaped: false,
  }
  // From here on the sidecar process exists and must be reaped on every
  // exit path; it also owns the temporary directory now.
  errdefer sidecar.close()
  sidecar.send(request.encode())
  match sidecar.events.next() {
    Some(Spawned(child_pid)) => {
      sidecar.child_pid = child_pid
      sidecar
    }
    Some(SpawnFailed(code)) =>
      raise @os_error.OSError(code, context="@pty.spawn")
    Some(Failed(code, what)) =>
      raise @os_error.OSError(code, context="@pty.spawn: sidecar: \{what}")
    Some(_) => raise SidecarError("the sidecar did not answer the spawn")
    None => raise SidecarError("the sidecar exited before spawning the child")
  }
}

///|
/// The pid of the child running on the terminal.
pub fn Sidecar::child_pid(self : Sidecar) -> Int32 {
  self.child_pid
}

///|
/// The terminal's output: stdout and stderr of the child, merged.
pub fn Sidecar::output(self : Sidecar) -> @async/process.ReadFromProcess {
  self.output
}

///|
/// Send one complete frame. Concurrent senders are serialized, and a frame
/// once started is not cut short by cancellation.
async fn Sidecar::send(self : Sidecar, frame : Bytes) -> Unit {
  self.send_lock.acquire()
  defer self.send_lock.release()
  guard !self.send_broken else {
    raise SidecarError("the command pipe broke during an earlier send")
  }
  @async.protect_from_cancel(() => {
    errdefer self.mark_send_broken()
    self.commands.write(frame)
  })
}

///|
fn Sidecar::mark_send_broken(self : Sidecar) -> Unit {
  self.send_broken = true
}

///|
fn Sidecar::apply(self : Sidecar, event : Event) -> Unit raise {
  match event {
    Wrote(n) => self.in_flight -= n
    WriteFailed(code) =>
      if self.write_error is None {
        self.write_error = Some(code)
      }
    Resized(code) => {
      let seq = self.resize_seen
      self.resize_seen += 1
      if self.resize_waiting.contains(seq) {
        self.resize_results[seq] = code
      }
    }
    Exit(status) => self.exit_status = Some(status)
    Failed(code, what) =>
      raise @os_error.OSError(code, context="@pty: sidecar: \{what}")
    Spawned(_) | SpawnFailed(_) =>
      raise SidecarError("unexpected spawn event from the sidecar")
  }
}

///|
/// Read and apply one event, unless another task is already reading one, in
/// which case wait for it to finish.
async fn Sidecar::pump_once(self : Sidecar) -> Unit {
  if self.reading {
    self.cond.wait()
    return
  }
  self.reading = true
  defer {
    self.reading = false
    self.cond.broadcast()
  }
  // A corrupt stream cannot be resynchronized: the error is kept, and
  // `pump_until` raises it to this and every later reader. Not an
  // `errdefer`, which also runs when the read is merely cancelled.
  let event = self.events.next() catch {
    error => {
      self.failure = Some(error)
      return
    }
  }
  if event is Some(event) {
    self.apply(event)
  } else {
    self.events_eof = true
  }
}

///|
/// Pump events until `done` holds or the sidecar has closed its event pipe.
async fn Sidecar::pump_until(self : Sidecar, done : () -> Bool) -> Unit {
  while !done() && !self.events_eof {
    if self.failure is Some(error) {
      raise error
    }
    self.pump_once()
  }
  if self.failure is Some(error) && !done() {
    raise error
  }
}

///|
/// Wait for the child to be reaped and return its exit code, or `-signal`
/// when it was killed by a signal (the `@async/process.wait_pid`
/// convention).
pub async fn Sidecar::wait(self : Sidecar) -> Int32 {
  self.pump_until(() => self.exit_status is Some(_))
  guard self.exit_status is Some(status) else {
    raise SidecarError("the sidecar exited without reporting the child's exit")
  }
  status
}

///|
/// Hand up to `len` bytes of `buf[offset:]` to the terminal and return how
/// many were taken; waits while too much earlier input is still unwritten.
pub async fn Sidecar::write_once(
  self : Sidecar,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  self.pump_until(() => {
    self.closed || self.write_error is Some(_) || self.in_flight < WRITE_WINDOW
  })
  if self.closed {
    raise @os_error.OSError(CLOSED_ERROR, context="@pty.Pty::write")
  }
  if self.write_error is Some(code) {
    raise @os_error.OSError(code, context="@pty.Pty::write")
  }
  guard self.in_flight < WRITE_WINDOW else {
    raise SidecarError("the sidecar exited")
  }
  let room = WRITE_WINDOW - self.in_flight
  let n = if len < room { len } else { room }
  let n = if n < MAX_WRITE { n } else { MAX_WRITE }
  self.in_flight += n
  self.send(encode_frame(CMD_WRITE, buf[offset:offset + n]))
  n
}

///|
/// Set the terminal size, in characters.
pub async fn Sidecar::resize(
  self : Sidecar,
  rows~ : Int32,
  cols~ : Int32,
) -> Unit {
  if self.closed {
    raise @os_error.OSError(CLOSED_ERROR, context="@pty.Pty::resize")
  }
  // Replies come back in command order, so each resize claims the next
  // sequence number before its command can be sent. A resize that is
  // cancelled while waiting stops being waited for, and its late reply is
  // dropped instead of being taken by the next one.
  let seq = self.resize_sent
  self.resize_sent += 1
  self.resize_waiting.add(seq)
  defer {
    self.resize_waiting.remove(seq)
    self.resize_results.remove(seq)
  }
  self.send(encode_resize(rows, cols))
  self.pump_until(() => self.resize_results.contains(seq))
  guard self.resize_results.get(seq) is Some(code) else {
    raise SidecarError("the sidecar exited before resizing the terminal")
  }
  if code != 0 {
    raise @os_error.OSError(code, context="@pty.Pty::resize")
  }
}

///|
/// Close the terminal: the child's session is hung up, and the output
/// stream ends.
pub async fn Sidecar::hangup(self : Sidecar) -> Unit {
  self.send(encode_frame(CMD_HANGUP, b""))
}

///|
/// Kill the child (its whole process group on Unix, its job on Windows).
pub async fn Sidecar::kill(self : Sidecar) -> Unit {
  self.send(encode_frame(CMD_KILL, b""))
}

///|
/// Stop reading the terminal's output. The sidecar keeps draining it, so a
/// child is never stuck writing to a terminal nobody reads.
pub fn Sidecar::close_output(self : Sidecar) -> Unit {
  self.output.close()
}

///|
/// Close every pipe to the sidecar and reap it. The sidecar ends the child
/// first if it is still running (hang up, grace period, kill). Safe to call
/// more than once.
pub async fn Sidecar::close(self : Sidecar) -> Unit nocancel {
  if self.closed {
    return
  }
  self.closed = true
  self.cond.broadcast()
  // The command pipe's EOF tells the sidecar to finish; it closes its event
  // pipe when it exits, which is what is waited for here (bounded, in case
  // it hangs).
  self.commands.close()
  self.output.close()
  @async.protect_from_cancel(() => {
    ignore(@async.with_timeout_opt(CLOSE_TIMEOUT_MS, () => self.drain_events()))
  })
  self.events_pipe.close()
  if self.reaped {
    return
  }
  self.reaped = true
  // Windows has no zombies to reap, and once the sidecar has exited its
  // pid may already name another process.
  if !(@async.platform is Windows) {
    @async.protect_from_cancel(() => {
      let _ = @async/process.wait_pid(self.pid) catch { _ => 0 }
    })
  }
  if self.temp_dir is Some(dir) {
    remove_temp_dir(dir)
  }
}

///|
/// How long `close` waits for the sidecar to exit. It exits at once when the
/// child is gone, and after the grace period plus a kill otherwise.
const CLOSE_TIMEOUT_MS : Int32 = 15000

///|
/// Read and discard events until the sidecar closes its event pipe.
async fn Sidecar::drain_events(self : Sidecar) -> Unit {
  let scratch = FixedArray::make(4096, b'\x00')
  for ;; {
    let n = self.events_pipe.read(scratch) catch { _ => break }
    if n == 0 {
      break
    }
  }
}
