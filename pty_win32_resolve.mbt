///|
// Userland executable resolution for win32. The candidates computed here are
// handed to the sidecar, which expands each with `GetFullPathNameW`, probes it
// with `GetFileAttributesW` and passes the first existing one to
// `CreateProcessW` as `lpApplicationName`, so that `cwd~` participates in the
// search and the parent's own cwd does not (see docs/internals.md
// "Executable resolution"). Drive-relative forms that need the parent's
// per-drive directories are left for that expansion.

///|
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
fn join_path(dir : StringView, file : StringView) -> String {
  if dir is [.., '/' | '\\'] {
    "\{dir}\{file}"
  } else {
    "\{dir}\\\{file}"
  }
}

///|
fn append_exe(file : StringView) -> String {
  for view = file {
    match view {
      [.., '.'] => break file.to_owned()
      [] | [.., '/' | '\\' | ':'] => break "\{file}.exe"
      [.. rest, _] => continue rest
    }
  } where {
    proof_invariant: view.length() <= file.length(),
    proof_reasoning: (
      #| each iteration strips the last code unit, so view is a
      #| strictly shorter suffix of file and the loop terminates
    ),
  }
}

///|
fn windows_path_candidates(
  file~ : StringView,
  path~ : StringView,
  cwd~ : String,
) -> FixedArray[String] {
  let file = append_exe(file)
  match (file, cwd) {
    (
      ['\\' | '/', '\\' | '/', ..]
      | ['A'..<='Z' | 'a'..<='z', ':', '\\' | '/', ..],
      _,
    ) => [file]
    (['\\' | '/', ..], ['A'..<='Z' | 'a'..<='z' as drive, ..]) =>
      ["\{drive}:\{file}"]
    (['\\' | '/', ..], _) => [file]
    (
      ['A'..<='Z' | 'a'..<='z' as file_drive, ':', .. relative_path],
      ['A'..<='Z' | 'a'..<='z' as current_drive, ..],
    ) =>
      if file_drive
        .to_ascii_uppercase()
        .equal(current_drive.to_ascii_uppercase()) {
        [join_path(cwd, relative_path)]
      } else {
        [file]
      }
    (['A'..<='Z' | 'a'..<='z', ':', ..], _) => [file]
    _ => {
      if file.contains_any(chars="/\\") {
        return [join_path(cwd, file)]
      }
      split_path_list(path).map(dir => join_path(dir, file))
    }
  }
}

///|
test "windows_path_candidates" {
  // Plain string manipulation: checked on every host, with a fixed cwd.
  let cwd = "C:\\Users\\MoonBit"
  let drive = 'C'
  // A drive letter that is NOT cwd's drive, for cross-drive cases below.
  let other = 'D'
  // Bare name: joined to every PATH entry, ".exe" appended; empty entries
  // are skipped, "." is kept.
  windows_path_candidates(file="echo", path=".\\test_data\\win32", cwd~)
  |> assert_eq([".\\test_data\\win32\\echo.exe"])
  windows_path_candidates(
    file="echo",
    path=".\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq([".\\test_data\\echo.exe", ".\\test_data\\win32\\echo.exe"])
  windows_path_candidates(
    file="echo",
    path=";.\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq([".\\test_data\\echo.exe", ".\\test_data\\win32\\echo.exe"])
  windows_path_candidates(
    file="echo",
    path=".;.\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq([
    ".\\echo.exe", ".\\test_data\\echo.exe", ".\\test_data\\win32\\echo.exe",
  ])
  // Empty PATH: a bare name gets no candidates.
  windows_path_candidates(file="echo", path="", cwd~) |> assert_eq([])
  // PATH list parsing: quoted entries may contain a literal ';' and the
  // quotes are stripped; a trailing separator is not doubled when joining.
  windows_path_candidates(file="echo", path="\"C:\\a;b\";C:\\c", cwd~)
  |> assert_eq(["C:\\a;b\\echo.exe", "C:\\c\\echo.exe"])
  windows_path_candidates(file="echo", path="C:\\bin\\", cwd~)
  |> assert_eq(["C:\\bin\\echo.exe"])
  // UNC (and device) forms: absolute by construction, never searched in
  // PATH nor joined to cwd.
  windows_path_candidates(
    file="\\\\server\\share\\echo",
    path=".\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq(["\\\\server\\share\\echo.exe"])
  // Drive-absolute: as-is, regardless of cwd's drive.
  windows_path_candidates(
    file="C:\\echo.exe",
    path=".\\test_data;.\\test_data\\win32",
    cwd="C:\\Users\\MoonBit",
  )
  |> assert_eq(["C:\\echo.exe"])
  windows_path_candidates(
    file="C:\\echo.exe",
    path=".\\test_data;.\\test_data\\win32",
    cwd="D:\\Projects\\Pty",
  )
  |> assert_eq(["C:\\echo.exe"])
  // Drive-relative (X:foo) on the same drive as cwd: joined to cwd.
  windows_path_candidates(
    file="D:echo.exe",
    path=".\\test_data;.\\test_data\\win32",
    cwd="D:\\Projects\\Pty",
  )
  |> assert_eq(["D:\\Projects\\Pty\\echo.exe"])
  // Drive-relative on another drive (or with a UNC cwd): left verbatim for
  // the sidecar's GetFullPathNameW, which expands it against the parent's
  // per-drive directory.
  windows_path_candidates(
    file="\{drive}:echo.exe",
    path=".\\test_data;.\\test_data\\win32",
    cwd="\{other}:\\Projects\\Pty",
  )
  |> assert_eq(["\{drive}:echo.exe"])
  windows_path_candidates(
    file="\{drive}:echo.exe",
    path=".\\test_data;.\\test_data\\win32",
    cwd="\\\\server\\share",
  )
  |> assert_eq(["\{drive}:echo.exe"])
  // An existing extension is preserved: .bat must not become .bat.exe.
  windows_path_candidates(
    file="echo.bat",
    path=".\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq([".\\test_data\\echo.bat", ".\\test_data\\win32\\echo.bat"])
  windows_path_candidates(
    file="C:\\echo.bat",
    path=".\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq(["C:\\echo.bat"])
  // ".exe" appending looks at the last component only: a dot in a
  // directory segment does not count, a trailing dot does.
  windows_path_candidates(file="test_data\\v1.2\\echo", path="", cwd="C:\\x")
  |> assert_eq(["C:\\x\\test_data\\v1.2\\echo.exe"])
  windows_path_candidates(file="foo.", path="C:\\bin", cwd~)
  |> assert_eq(["C:\\bin\\foo."])
  // Relative path with a separator: joined to cwd, PATH ignored.
  windows_path_candidates(
    file="test_data\\win32\\echo.bat",
    path=".\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq([join_path(cwd, "test_data\\win32\\echo.bat")])
  windows_path_candidates(
    file="test_data\\win32\\echo",
    path=".\\test_data;.\\test_data\\win32",
    cwd~,
  )
  |> assert_eq([join_path(cwd, "test_data\\win32\\echo.exe")])
  windows_path_candidates(file=".\\echo", path="ignored", cwd="C:\\proj")
  |> assert_eq(["C:\\proj\\.\\echo.exe"])
  // Root-relative (\foo): takes cwd's drive; a UNC cwd has none, so the
  // path is left for the system to resolve.
  windows_path_candidates(file="\\echo", path=".\\test_data", cwd~)
  |> assert_eq(["\{drive}:\\echo.exe"])
  windows_path_candidates(
    file="\\echo",
    path=".\\test_data",
    cwd="\\\\server\\share",
  )
  |> assert_eq(["\\echo.exe"])
  // Forward slashes are separators everywhere.
  windows_path_candidates(file="C:/echo.exe", path="ignored", cwd~)
  |> assert_eq(["C:/echo.exe"])
  windows_path_candidates(file="//server/share/echo", path="ignored", cwd~)
  |> assert_eq(["//server/share/echo.exe"])
  windows_path_candidates(file="./echo", path="ignored", cwd="C:\\proj")
  |> assert_eq(["C:\\proj\\./echo.exe"])
  // Drive letters compare case-insensitively.
  windows_path_candidates(file="d:echo.exe", path="", cwd="D:\\Projects")
  |> assert_eq(["D:\\Projects\\echo.exe"])
  windows_path_candidates(file="c:\\echo.exe", path="", cwd~)
  |> assert_eq(["c:\\echo.exe"])
}
