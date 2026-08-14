///|
// Userland executable resolution for win32: `spawn` probes these candidates
// with `win32_file_exists` and hands the winner to `CreateProcessW`'s
// `lpApplicationName`, so that `cwd~` participates in the search and the
// parent's own cwd does not (see README "Executable resolution").

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
