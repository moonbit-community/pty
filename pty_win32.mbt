///|
#cfg(platform="windows")
let invalid_handle : @handle.Handle = @handle.Handle::invalid()

///|
#cfg(platform="windows")
#borrow(pty)
extern "c" fn pty_win32_open(
  pty : FixedArray[@handle.Handle],
  rows~ : Int,
  cols~ : Int,
) -> Int = "moonbit_pty_win32_open"

///|
#cfg(platform="windows")
#borrow(hpc, session, cmd, app, env, cwd)
extern "c" fn pty_win32_spawn(
  hpc : PseudoConsole,
  session : FixedArray[@handle.Handle],
  cmd~ : String,
  app~ : String,
  env~ : String,
  cwd~ : String,
) -> Int = "moonbit_pty_win32_spawn"

///|
#cfg(platform="windows")
priv struct PseudoConsole(@handle.Handle)

///|
#cfg(platform="windows")
#borrow(hpc)
extern "c" fn PseudoConsole::close(hpc : PseudoConsole) = "ClosePseudoConsole"

///|
#cfg(platform="windows")
struct Pty {
  input_writer : @async/raw_fd.RawFdStream
  output_reader : @async/raw_fd.RawFdStream
  hpc : Ref[PseudoConsole?]
  pid : Int
  result : @async.Task[Int]
}

///|
#cfg(platform="windows")
const ERROR_FILE_NOT_FOUND : Int = 2

///|
#cfg(platform="windows")
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
  let env_map : Map[String, (String, String)] = Map([])
  if inherit_env {
    for k, v in @env.get_env_vars() {
      env_map[k.to_upper()] = (k, v)
    }
  }
  for k, v in extra_env {
    let uk = k.to_upper()
    env_map[uk] = if env_map.get(uk) is Some((ok, _)) {
      (ok, v)
    } else {
      (k, v)
    }
  }
  let env = {
    let sb = StringBuilder()
    for _, kv in env_map {
      let (k, v) = kv
      sb <+ "\{k}=\{v}\u{0000}"
    }
    sb.write_char('\u{000}')
    sb.to_string()
  }
  let cwd = {
    let cwd = if cwd is Some(cwd) { cwd.to_owned() } else { "." }
    get_full_path_name(cwd)
  }
  // Build the command line the way `CommandLineToArgvW` would parse it back
  // into `[file, ..args]`. `CreateProcessW` mutates this buffer in place, so
  // `to_string` must hand back a fresh heap copy (never a string literal).
  let cmd = {
    let sb = StringBuilder::new()
    sb.write_arg_with_windows_escape(file)
    for arg in args {
      sb..write_char(' ').write_arg_with_windows_escape(arg)
    }
    sb.to_string()
  }
  let app = {
    let path = if env_map.get("PATH") is Some((_, path)) { path } else { "" }
    let candidates = get_path_candidates(file~, path~, cwd~)
    for candidate in candidates {
      if win32_file_exists(candidate) {
        break candidate
      }
    } nobreak {
      raise @os_error.OSError(ERROR_FILE_NOT_FOUND, context="@pty.spawn")
    }
  }
  let pty : FixedArray[@handle.Handle] = [
    invalid_handle, invalid_handle, invalid_handle,
  ]
  if pty_win32_open(pty, rows~, cols~) < 0 {
    raise @os_error.OSError(@os_error.get_errno(), context="@pty.open")
  }
  guard! pty is [input_writer_handle, output_reader_handle, hpc_handle]
  let hpc = PseudoConsole(hpc_handle)
  let input_writer = {
    errdefer {
      output_reader_handle.close()
      hpc.close()
    }
    input_writer_handle.to_raw_fd_stream()
  }
  let output_reader = {
    errdefer {
      input_writer.close()
      hpc.close()
    }
    output_reader_handle.to_raw_fd_stream()
  }
  let session : FixedArray[@handle.Handle] = [invalid_handle, invalid_handle]
  let pid = pty_win32_spawn(hpc, session, cmd~, app~, env~, cwd~)
  if pid < 0 {
    input_writer.close()
    output_reader.close()
    hpc.close()
    raise @os_error.OSError(@os_error.get_errno(), context="@pty.spawn")
  }
  guard! session is [process_handle, job_handle]
  let process = Process(process_handle)
  let job = JobObject(job_handle)
  let hpc = Ref(Some(hpc))
  fn close_pseudo_console() -> Unit {
    if hpc.val is Some(h) {
      h.close()
      hpc.val = None
    }
  }
  let result = group.spawn(no_wait?) <| () => {
    defer (if !job.is_invalid() { job.close() })
    defer process.close()
    defer close_pseudo_console()
    @async/process.wait_pid(pid) catch {
      error if @async.is_being_cancelled() => {
        // Reap the child even though we are being cancelled, then propagate
        // the cancellation like `@async/process.spawn` does.
        let _ = @async.protect_from_cancel() <| () => {
          wait_pid_with(pid) <| () => {
            close_pseudo_console()
            // Grace period before the hard kill; matches the ~5s the OS
            // itself grants on CTRL_CLOSE_EVENT. Keep in sync with the
            // unix side (pty_unix.mbt), which is not type-checked here.
            @async.sleep(5000)
            if !job.is_invalid() {
              job.terminate(1) |> ignore()
            } else {
              process.terminate(1) |> ignore()
            }
          }
        }
        raise error
      }
      error => raise error
    }
  }
  group.add_defer() <| () => {
    input_writer.close()
    output_reader.close()
  }
  { input_writer, output_reader, hpc, pid, result }
}

///|
#cfg(platform="windows")
const ERROR_BROKEN_PIPE : Int = 109

///|
#cfg(platform="windows")
pub impl @async/io.Reader for Pty with fn _direct_read(
  self : Pty,
  buf : FixedArray[Byte],
  offset~ : Int,
  max_len~ : Int,
) -> Int {
  self.output_reader._direct_read(buf, offset~, max_len~) catch {
    @os_error.OSError(ERROR_BROKEN_PIPE, ..) => 0
    error => raise error
  }
}

///|
#cfg(platform="windows")
#warnings("-alert_internal")
pub impl @async/io.Reader for Pty with fn _get_internal_buffer(self : Pty) -> @async/io.ReaderBuffer {
  self.output_reader._get_internal_buffer()
}

///|
#cfg(platform="windows")
pub impl @async/io.Writer for Pty with fn write_once(
  self : Pty,
  buf : Bytes,
  offset~ : Int,
  len~ : Int,
) -> Int {
  self.input_writer.write_once(buf, offset~, len~)
}

///|
#cfg(platform="windows")
#borrow(hpc)
extern "c" fn PseudoConsole::resize(
  hpc : PseudoConsole,
  rows~ : Int,
  cols~ : Int,
) -> Int = "moonbit_pty_win32_resize"

///|
#cfg(platform="windows")
pub fn Pty::resize(
  self : Pty,
  rows~ : Int,
  cols~ : Int,
) -> Unit raise @os_error.OSError {
  guard self.hpc.val is Some(hpc) else {
    raise @os_error.OSError(9, context="@pty.Pty::resize")
  }
  if hpc.resize(rows~, cols~) < 0 {
    raise @os_error.OSError(@os_error.get_errno(), context="@pty.Pty::resize")
  }
}

///|
#cfg(platform="windows")
pub async fn Pty::wait(self : Pty) -> Int {
  return self.result.wait()
}

///|
#cfg(platform="windows")
priv struct JobObject(@handle.Handle)

///|
#cfg(platform="windows")
#borrow(job)
extern "c" fn JobObject::terminate(job : JobObject, exit_code : Int) -> Bool = "TerminateJobObject"

///|
#cfg(platform="windows")
fn JobObject::close(self : JobObject) -> Unit {
  self.0.close()
}

///|
#cfg(platform="windows")
fn JobObject::is_invalid(self : JobObject) -> Bool {
  self.0 == invalid_handle
}

///|
#cfg(platform="windows")
priv struct Process(@handle.Handle)

///|
#cfg(platform="windows")
#borrow(process)
extern "c" fn Process::terminate(process : Process, exit_code : UInt) -> Bool = "TerminateProcess"

///|
#cfg(platform="windows")
fn Process::close(self : Process) -> Unit {
  self.0.close()
}

///|
#cfg(platform="windows")
pub fn Pty::pid(self : Pty) -> Int {
  self.pid
}

///|
#cfg(platform="windows")
let _unused_packages : Unit = ignore(@encoding/utf8.encode("hello"))
