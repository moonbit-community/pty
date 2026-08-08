///|
#cfg(platform="windows")
#borrow(pty)
extern "c" fn pty_win32_open(
  pty : FixedArray[Handle],
  rows~ : Int,
  cols~ : Int,
) -> Int = "moonbit_pty_win32_open"

///|
#cfg(platform="windows")
#borrow(pty, cmd, env, cwd)
extern "c" fn pty_win32_spawn(
  pty : FixedArray[Handle],
  cmd~ : String,
  env~ : String,
  cwd~ : String,
) -> Int = "moonbit_pty_win32_spawn"

///|
#cfg(platform="windows")
priv struct Handle(@async/types.Fd)

///|
#cfg(platform="windows")
extern "c" fn Handle::invalid() -> Handle = "moonbit_pty_win32_get_invalid_handle"

///|
#cfg(platform="windows")
extern "c" fn Handle::close(handle : Handle) -> Unit = "CloseHandle"

///|
#cfg(platform="windows")
extern "c" fn Handle::is_invalid(self : Handle) -> Bool = "moonbit_pty_win32_is_invalid_handle"

///|
#cfg(platform="windows")
let invalid_handle : Handle = Handle::invalid()

///|
#cfg(platform="windows")
priv struct PseudoConsole(Handle)

///|
#cfg(platform="windows")
extern "c" fn PseudoConsole::close(hpc : PseudoConsole) = "ClosePseudoConsole"

///|
#cfg(platform="windows")
struct Pty {
  closed : Ref[Bool]
  input_writer : @async/raw_fd.RawFdStream
  output_reader : @async/raw_fd.RawFdStream
  hpc : PseudoConsole
  pid : Int
  result : @async.Task[Int]
}

///|
#cfg(platform="windows")
pub async fn[X] spawn(
  group : @async.TaskGroup[X],
  rows~ : Int,
  cols~ : Int,
  cmdline : StringView,
  inherit_env? : Bool = true,
  extra_env? : Map[String, String] = Map([]),
  cwd? : StringView,
) -> Pty {
  let pty : FixedArray[Handle] = [
    invalid_handle, invalid_handle, invalid_handle, invalid_handle, invalid_handle,
  ]
  if pty_win32_open(pty, rows~, cols~) < 0 {
    raise @os_error.OSError(@os_error.get_errno(), context="@pty.open")
  }
  let input_writer_handle = pty[0]
  let output_reader_handle = pty[1]
  let hpc = PseudoConsole(pty[2])
  let input_writer = @async/raw_fd.RawFdStream(input_writer_handle.0) catch {
    error => {
      output_reader_handle.close()
      hpc.close()
      raise error
    }
  }
  let output_reader = @async/raw_fd.RawFdStream(output_reader_handle.0) catch {
    error => {
      input_writer.close()
      hpc.close()
      raise error
    }
  }
  let env = {
    let env = StringBuilder()
    if inherit_env {
      for k, v in @env.get_env_vars() {
        env <+ "\{k}=\{v}\u{0000}"
      }
    }
    for k, v in extra_env {
      env <+ "\{k}=\{v}\u{0000}"
    }
    env.write_char('\u{000}')
    env.to_string()
  }
  let cwd = if cwd is Some(cwd) { cwd.to_owned() } else { "" }
  let pid = pty_win32_spawn(pty, cmd=cmdline.to_owned(), env~, cwd~)
  if pid < 0 {
    input_writer.close()
    output_reader.close()
    hpc.close()
    raise @os_error.OSError(@os_error.get_errno(), context="@pty.spawn")
  }
  let process = Process(pty[3])
  let job = JobObject(pty[4])
  let closed = Ref(false)
  let result = group.spawn() <| () => {
    defer (if !job.is_invalid() { job.close() })
    defer process.close()
    @async/process.wait_pid(pid) catch {
      _ if @async.is_being_cancelled() =>
        @async.protect_from_cancel() <| () => {
          @async.with_task_group() <| g => {
            g.spawn_bg(no_wait=true) <| () => {
              guard !closed.val else { return }
              closed.val = true
              if !job.is_invalid() {
                job.terminate(1) |> ignore()
              } else {
                process.terminate(1) |> ignore()
              }
            }
            @async/process.wait_pid(pid)
          }
        }
      error => raise error
    }
  }
  let pty = Pty::{ closed, input_writer, output_reader, hpc, pid, result }
  group.add_defer() <| () => { pty.close() }
  pty
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
  if self.hpc.resize(rows~, cols~) < 0 {
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
priv struct JobObject(Handle)

///|
#cfg(platform="windows")
extern "c" fn JobObject::terminate(job : JobObject, exit_code : Int) -> Bool = "TerminateJobObject"

///|
#cfg(platform="windows")
fn JobObject::close(self : JobObject) -> Unit {
  self.0.close()
}

///|
#cfg(platform="windows")
fn JobObject::is_invalid(self : JobObject) -> Bool {
  self.0.is_invalid()
}

///|
#cfg(platform="windows")
priv struct Process(Handle)

///|
#cfg(platform="windows")
extern "c" fn Process::terminate(process : Process, exit_code : UInt) -> Bool = "TerminateProcess"

///|
#cfg(platform="windows")
fn Process::close(self : Process) -> Unit {
  self.0.close()
}

///|
#cfg(platform="windows")
pub fn Pty::close(self : Pty) -> Unit {
  guard !self.closed.val else { return }
  self.closed.val = true
  self.input_writer.close()
  self.output_reader.close()
  self.hpc.close()
}

///|
#cfg(platform="windows")
pub fn Pty::pid(self : Pty) -> Int {
  self.pid
}

///|
let _unused_packages : Unit = {
  ignore(@encoding/utf8.encode("hello"))
  ignore(@async/pipe.pipe)
}
