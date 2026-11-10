///|
/// The SPAWN request for a Windows sidecar: the command line
/// `CommandLineToArgvW` parses back into `[file, ..args]`, the merged
/// environment, and the `lpApplicationName` candidates.
fn windows_spawn_request(
  rows~ : Int32,
  cols~ : Int32,
  file~ : StringView,
  args~ : ArrayView[StringView],
  extra_env~ : Map[String, String],
  inherit_env~ : Bool,
  cwd~ : StringView?,
) -> @sidecar.SpawnRequest {
  // Windows environment keys are case-insensitive: an `extra_env` key
  // overrides an inherited one spelled differently, and keeps the inherited
  // spelling.
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
  let cmd = {
    let sb = StringBuilder()
    sb.write_arg_with_windows_escape(file)
    for arg in args {
      sb..write_char(' ').write_arg_with_windows_escape(arg)
    }
    sb.to_string()
  }
  // Candidates are joined to an absolute cwd, like `GetFullPathNameW` would
  // have made it: a relative `cwd` is relative to the parent's directory.
  let base = @env.current_dir().unwrap_or(".")
  let resolve_cwd = match cwd {
    None => base
    Some(['\\' | '/', ..] | ['A'..<='Z' | 'a'..<='z', ':', ..]) =>
      cwd.unwrap_or(base).to_owned()
    Some(cwd) => join_path(base, cwd)
  }
  let path = if env_map.get("PATH") is Some((_, path)) { path } else { "" }
  {
    rows,
    cols,
    candidates: [..windows_path_candidates(file~, path~, cwd=resolve_cwd)],
    argv: [cmd],
    env: [
      for _, (k, v) in env_map => "\{k}=\{v}"
    ],
    cwd: Some(resolve_cwd),
  }
}
