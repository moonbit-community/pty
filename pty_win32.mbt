///|
#cfg(platform="windows")
extern "c" fn pty_win32_get_invalid_handle() -> @handle.Handle = "moonbit_pty_win32_get_invalid_handle"

///|
#cfg(platform="windows")
let invalid_handle : @handle.Handle = pty_win32_get_invalid_handle()

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
// Append `arg` to a Windows command line, quoting/escaping it so that
// `CommandLineToArgvW` (and the C runtime's argv parser) recovers `arg`
// verbatim. Ported from moonbitlang/async's `write_arg_with_windows_escape`.
// The rules come from
// https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments:
// backslashes are literal unless they precede a `"`, in which case each is
// doubled and the `"` is escaped as `\"`.
#cfg(platform="windows")
fn StringBuilder::write_arg_with_windows_escape(
  builder : StringBuilder,
  arg : StringView,
) -> Unit {
  if arg is "" {
    builder.write("\"\"")
    return
  }
  // Do not add double quotes if it is unnecessary to do so.
  // This helps with simple cases when the program is not using C argv syntax,
  // such as `rundll32.exe`.
  let need_quote = for char in arg {
    if char is (' ' | '\t' | '"') {
      break true
    }
  } nobreak {
    false
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
        builder <+ "\\\""
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
priv struct PseudoConsole(@handle.Handle)

///|
#cfg(platform="windows")
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
  let session : FixedArray[@handle.Handle] = [invalid_handle, invalid_handle]
  let pid = pty_win32_spawn(hpc, session, cmd~, app~, env~, cwd~)
  if pid < 0 {
    input_writer.close()
    output_reader.close()
    hpc.close()
    raise @os_error.OSError(@os_error.get_errno(), context="@pty.spawn")
  }
  let process = Process(session[0])
  let job = JobObject(session[1])
  let hpc = Ref(Some(hpc))
  fn close_pseudo_console() -> Unit {
    if hpc.val is Some(h) {
      h.close()
      hpc.val = None
    }
  }
  let result = group.spawn() <| () => {
    defer (if !job.is_invalid() { job.close() })
    defer process.close()
    defer close_pseudo_console()
    @async/process.wait_pid(pid) catch {
      _ if @async.is_being_cancelled() =>
        @async.protect_from_cancel() <| () => {
          @async.with_task_group() <| g => {
            g.spawn_bg(no_wait=true) <| () => {
              close_pseudo_console()
              @async.sleep(5000)
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

///|
#cfg(platform="windows")
#borrow(path)
extern "c" fn win32_get_full_path_name(path : String) -> String = "moonbit_pty_win32_get_full_path_name"

///|
#cfg(platform="windows")
fn get_full_path_name(path : String) -> String raise @os_error.OSError {
  let full_path_name = win32_get_full_path_name(path)
  if full_path_name.is_empty() {
    raise @os_error.OSError(@os_error.get_errno(), context="@pty.spawn")
  } else {
    full_path_name
  }
}

///|
#cfg(platform="windows")
#borrow(path)
extern "c" fn win32_file_exists(path : String) -> Bool = "moonbit_pty_win32_file_exists"

///|
#cfg(platform="windows")
fn split_path_list(path : StringView) -> FixedArray[String] {
  let entries = []
  let entry = StringBuilder()
  fn flush() {
    if !entry.is_empty() {
      entries.push(entry.to_string())
      entry.reset()
    }
  }
  let mut quoted = false
  for c in path {
    match c {
      '"' => quoted = !quoted
      ';' if !quoted => flush()
      c => entry.write_char(c)
    }
  }
  flush()
  FixedArray::from_array(entries)
}

///|
#cfg(platform="windows")
fn join_path(dir : StringView, file : StringView) -> String {
  if dir is [.., '/' | '\\'] {
    "\{dir}\{file}"
  } else {
    "\{dir}\\\{file}"
  }
}

///|
#cfg(platform="windows")
fn append_exe(file : StringView) -> String {
  for view = file {
    match view {
      [.., '.'] => break file.to_owned()
      [] | [.., '/' | '\\' | ':'] => break "\{file}.exe"
      [.. rest, _] => continue rest
    }
  }
}

///|
#cfg(platform="windows")
fn get_path_candidates(
  file~ : StringView,
  path~ : StringView,
  cwd~ : String,
) -> FixedArray[String] raise @os_error.OSError {
  let file = append_exe(file)
  match (file, cwd) {
    (
      ['\\' | '/', '\\' | '/', ..]
      | ['A'..='Z' | 'a'..='z', ':', '\\' | '/', ..],
      _,
    ) => [file]
    (['\\' | '/', ..], ['A'..='Z' | 'a'..='z' as drive, ..]) =>
      ["\{drive}:\{file}"]
    (['\\' | '/', ..], _) => [file]
    (
      ['A'..='Z' | 'a'..='z' as file_drive, ':', .. relative_path],
      ['A'..='Z' | 'a'..='z' as current_drive, ..],
    ) =>
      if file_drive
        .to_ascii_uppercase()
        .equal(current_drive.to_ascii_uppercase()) {
        [join_path(cwd, relative_path)]
      } else {
        [get_full_path_name(file)]
      }
    (['A'..='Z' | 'a'..='z', ':', ..], _) => [get_full_path_name(file)]
    _ => {
      if file.contains_any(chars="/\\") {
        return [join_path(cwd, file)]
      }
      split_path_list(path).map(dir => join_path(dir, file))
    }
  }
}

///|
#cfg(platform="windows")
test "get_path_candidates" {
  let cwd = get_full_path_name(".")
  guard cwd is ['A'..='Z' | 'a'..='z' as drive, ..] else {
    fail("get_path_candidates: unable to parse current drive")
  }
  // A drive letter that is NOT the parent's current drive, for cross-drive
  // cases below.
  let other = if drive is ('D' | 'd') { 'C' } else { 'D' }
  // Bare name: joined to every PATH entry, ".exe" appended; empty entries
  // are skipped, "." is kept.
  get_path_candidates(file="echo", path=".\\test_data\\win32", cwd~)
  |> assert_eq([".\\test_data\\win32\\echo.exe"])
  get_path_candidates(
    file="echo",
    path=".\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq([".\\test_data\\echo.exe", ".\\test_data\\win32\\echo.exe"])
  get_path_candidates(
    file="echo",
    path=";.\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq([".\\test_data\\echo.exe", ".\\test_data\\win32\\echo.exe"])
  get_path_candidates(
    file="echo",
    path=".;.\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq([
    ".\\echo.exe", ".\\test_data\\echo.exe", ".\\test_data\\win32\\echo.exe",
  ])
  // Empty PATH: a bare name gets no candidates.
  get_path_candidates(file="echo", path="", cwd~) |> assert_eq([])
  // PATH list parsing: quoted entries may contain a literal ';' and the
  // quotes are stripped; a trailing separator is not doubled when joining.
  get_path_candidates(file="echo", path="\"C:\\a;b\";C:\\c", cwd~)
  |> assert_eq(["C:\\a;b\\echo.exe", "C:\\c\\echo.exe"])
  get_path_candidates(file="echo", path="C:\\bin\\", cwd~)
  |> assert_eq(["C:\\bin\\echo.exe"])
  // UNC (and device) forms: absolute by construction, never searched in
  // PATH nor joined to cwd.
  get_path_candidates(
    file="\\\\server\\share\\echo",
    path=".\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq(["\\\\server\\share\\echo.exe"])
  // Drive-absolute: as-is, regardless of cwd's drive.
  get_path_candidates(
    file="C:\\echo.exe",
    path=".\\test_data;.\\test_data\\win32",
    cwd="C:\\Users\\MoonBit",
  )
  |> assert_eq(["C:\\echo.exe"])
  get_path_candidates(
    file="C:\\echo.exe",
    path=".\\test_data;.\\test_data\\win32",
    cwd="D:\\Projects\\Pty",
  )
  |> assert_eq(["C:\\echo.exe"])
  // Drive-relative (X:foo) on the same drive as cwd: joined to cwd.
  get_path_candidates(
    file="D:echo.exe",
    path=".\\test_data;.\\test_data\\win32",
    cwd="D:\\Projects\\Pty",
  )
  |> assert_eq(["D:\\Projects\\Pty\\echo.exe"])
  // Drive-relative on another drive (or with a UNC cwd): expanded via
  // GetFullPathNameW against the parent's ambient state. Using the
  // parent's own drive as X makes the expansion deterministic on any
  // machine: the parent cwd IS that drive's current directory.
  get_path_candidates(
    file="\{drive}:echo.exe",
    path=".\\test_data;.\\test_data\\win32",
    cwd="\{other}:\\Projects\\Pty",
  )
  |> assert_eq([join_path(cwd, "echo.exe")])
  get_path_candidates(
    file="\{drive}:echo.exe",
    path=".\\test_data;.\\test_data\\win32",
    cwd="\\\\server\\share",
  )
  |> assert_eq([join_path(cwd, "echo.exe")])
  // An existing extension is preserved: .bat must not become .bat.exe.
  get_path_candidates(
    file="echo.bat",
    path=".\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq([".\\test_data\\echo.bat", ".\\test_data\\win32\\echo.bat"])
  get_path_candidates(
    file="C:\\echo.bat",
    path=".\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq(["C:\\echo.bat"])
  // ".exe" appending looks at the last component only: a dot in a
  // directory segment does not count, a trailing dot does.
  get_path_candidates(file="test_data\\v1.2\\echo", path="", cwd="C:\\x")
  |> assert_eq(["C:\\x\\test_data\\v1.2\\echo.exe"])
  get_path_candidates(file="foo.", path="C:\\bin", cwd~)
  |> assert_eq(["C:\\bin\\foo."])
  // Relative path with a separator: joined to cwd, PATH ignored.
  get_path_candidates(
    file="test_data\\win32\\echo.bat",
    path=".\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq([join_path(cwd, "test_data\\win32\\echo.bat")])
  get_path_candidates(
    file="test_data\\win32\\echo",
    path=".\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq([join_path(cwd, "test_data\\win32\\echo.exe")])
  get_path_candidates(file=".\\echo", path="ignored", cwd="C:\\proj")
  |> assert_eq(["C:\\proj\\.\\echo.exe"])
  // Root-relative (\foo): takes cwd's drive; a UNC cwd has none, so the
  // path is left for the system to resolve.
  get_path_candidates(file="\\echo", path=".\\test_data", cwd~)
  |> assert_eq(["\{drive}:\\echo.exe"])
  get_path_candidates(
    file="\\echo",
    path=".\\test_data",
    cwd="\\\\server\\share",
  )
  |> assert_eq(["\\echo.exe"])
  // Forward slashes are separators everywhere.
  get_path_candidates(file="C:/echo.exe", path="ignored", cwd~)
  |> assert_eq(["C:/echo.exe"])
  get_path_candidates(file="//server/share/echo", path="ignored", cwd~)
  |> assert_eq(["//server/share/echo.exe"])
  get_path_candidates(file="./echo", path="ignored", cwd="C:\\proj")
  |> assert_eq(["C:\\proj\\./echo.exe"])
  // Drive letters compare case-insensitively.
  get_path_candidates(file="d:echo.exe", path="", cwd="D:\\Projects")
  |> assert_eq(["D:\\Projects\\echo.exe"])
  get_path_candidates(file="c:\\echo.exe", path="", cwd~)
  |> assert_eq(["c:\\echo.exe"])
}
