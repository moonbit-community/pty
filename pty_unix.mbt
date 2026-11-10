///|
/// The SPAWN request for a Unix sidecar: the child's argv, environment and
/// `execve` candidates, computed the way `execvp` would.
fn unix_spawn_request(
  rows~ : Int32,
  cols~ : Int32,
  file~ : StringView,
  args~ : ArrayView[StringView],
  extra_env~ : Map[String, String],
  inherit_env~ : Bool,
  cwd~ : StringView?,
) -> @sidecar.SpawnRequest {
  let env = if inherit_env { @env.get_env_vars() } else { Map([]) }
  for k, v in extra_env {
    env[k] = v
  }
  let candidates = unix_path_candidates(
    file~,
    path=env.get_or_default("PATH", "/usr/bin:/bin"),
  )
  // `argv[0]` is `file` verbatim, not the candidate `execve` picked. This is
  // what `execvp` (hence moonbitlang/async's `posix_spawnp`) does, and programs
  // that dispatch on `argv[0]` — busybox-style multi-call binaries, shells
  // checking for a leading `-` — need to see what the caller wrote.
  let argv = [file.to_owned(), ..args.map(arg => arg.to_owned())]
  {
    rows,
    cols,
    candidates,
    argv,
    env: [
      for k, v in env => "\{k}=\{v}"
    ],
    cwd: cwd.map(cwd => cwd.to_owned()),
  }
}

///|
fn unix_path_candidates(
  file~ : StringView,
  path~ : StringView,
) -> Array[String] {
  if file.contains_char('/') {
    return [file.to_owned()]
  }
  let view = path[:]
  let candidates = []
  for p = view, dirp = view {
    match p {
      ([] as rest) | [':', .. rest] => {
        // Empty entries are skipped, not read as the current directory (the
        // traditional execvp reading): a bare name never resolves against
        // `cwd` unless PATH names it explicitly. See docs/internals.md.
        let dir = path[dirp.start_offset():p.start_offset()]
        if !dir.is_empty() {
          candidates.push("\{dir}/\{file}")
        }
        if rest is [] {
          break candidates
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

///|
test "unix_path_candidates" {
  // Plain string manipulation: checked on every host.
  assert_eq(unix_path_candidates(file="sh", path="/usr/bin:/bin"), [
    "/usr/bin/sh", "/bin/sh",
  ])
  assert_eq(unix_path_candidates(file="/usr/bin/sh", path="/bin:/usr/bin"), [
    "/usr/bin/sh",
  ])
  assert_eq(unix_path_candidates(file="./relative", path="/bin"), ["./relative"])
  assert_eq(unix_path_candidates(file="nosuchprog", path="/usr/bin:/bin"), [
    "/usr/bin/nosuchprog", "/bin/nosuchprog",
  ])
  // Empty entries — leading, trailing, doubled, or the whole PATH — yield no
  // candidate; "." is an ordinary entry and is kept.
  assert_eq(unix_path_candidates(file="sh", path=""), [])
  assert_eq(unix_path_candidates(file="sh", path=":"), [])
  assert_eq(unix_path_candidates(file="sh", path=":/bin"), ["/bin/sh"])
  assert_eq(unix_path_candidates(file="sh", path="/bin:"), ["/bin/sh"])
  assert_eq(unix_path_candidates(file="sh", path="/usr/bin::/bin"), [
    "/usr/bin/sh", "/bin/sh",
  ])
  assert_eq(unix_path_candidates(file="sh", path=".:/bin"), ["./sh", "/bin/sh"])
}
