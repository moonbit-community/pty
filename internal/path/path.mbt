///|
/// PATH candidates for `file`, in the order `execve` should try them.
///
/// `file` containing a path separator is used verbatim; otherwise it is looked
/// up through `path`, first match wins. Empty entries (a leading or trailing
/// separator, a doubled one, or an empty `path`) are skipped, so an empty
/// `path` means a bare name is simply not found, and a bare name never
/// resolves against the child's working directory unless `path` names it
/// explicitly. See docs/internals.md.
///
/// This is the wasm backend's copy of the rule; `get_path_candidates` in
/// `pty_unix.mbt` is the native one, and the two have to stay in sync. They
/// cannot share code: the native package is not importable from a wasm
/// package, and a shared package imported by the root package would be an
/// unused import on Windows, which `moon check --deny-warn` rejects.
pub fn get_path_candidates(
  file~ : StringView,
  path~ : StringView,
) -> FixedArray[Bytes] {
  if file.contains_char('/') {
    return [@encoding/utf8.encode(file)]
  }
  // `path` is already a `StringView`; `view()` would only return it, and is
  // deprecated.
  let view = path
  let candidates = []
  for p = view, dirp = view {
    match p {
      ([] as rest) | [':', .. rest] => {
        // Empty entries are skipped, not read as the current directory (the
        // traditional execvp reading): a bare name never resolves against
        // `cwd` unless PATH names it explicitly. See docs/internals.md.
        let dir = path[dirp.start_offset():p.start_offset()]
        if !dir.is_empty() {
          candidates.push(@encoding/utf8.encode("\{dir}/\{file}"))
        }
        if rest is [] {
          break FixedArray::from_array(candidates)
        } else {
          continue rest, rest
        }
      }
      [_, .. rest] => continue rest, dirp
    }
  } where {
    proof_invariant: dirp.start_offset() <= p.start_offset(),
    proof_invariant: p.length() <= view.length(),
    proof_reasoning: (
      #| p advances one code unit per iteration, or is reset to
      #| rest after emitting a segment; dirp stays put or moves forward to rest,
      #| so both stay inside view and p strictly shrinks on every path
    ),
  }
}
