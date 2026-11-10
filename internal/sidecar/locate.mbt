///|
/// Environment variable naming an external sidecar executable to use instead
/// of the embedded one.
const SIDECAR_ENV : String = "PTY_SIDECAR"

///|
/// `<os>-<arch>` of the running host, the key into `embedded_sidecars`.
/// Computed once: on Unix it takes running `uname -m`.
let platform_key_cache : Ref[String?] = Ref(None)

///|
async fn platform_key() -> String {
  if platform_key_cache.val is Some(key) {
    return key
  }
  let os = match @async.platform {
    Linux => "linux"
    MacOS => "macos"
    Windows => "windows"
  }
  let arch = match @async.platform {
    Windows =>
      match @env.get_env_var("PROCESSOR_ARCHITECTURE") {
        Some("ARM64") => "arm64"
        _ => "x86_64"
      }
    Linux | MacOS => {
      let (exit, out) = @async/process.collect_stdout("uname", ["-m"])
      guard exit == 0 else { return "\{os}-unknown" }
      match out.text().trim().to_owned() {
        "aarch64" | "arm64" => "arm64"
        "x86_64" | "amd64" => "x86_64"
        other => other
      }
    }
  }
  let key = "\{os}-\{arch}"
  platform_key_cache.val = Some(key)
  key
}

///|
/// The sidecar executable to start, and the temporary directory holding it
/// when it had to be written out for this sidecar alone (removed once the
/// sidecar is reaped).
async fn locate() -> (String, String?) {
  if @env.get_env_var(SIDECAR_ENV) is Some(path) && path != "" {
    return (path, None)
  }
  let key = platform_key()
  guard embedded_sidecars.get(key) is Some(executable) else {
    raise @os_error.OSError(
      enotsup(),
      context="@pty.spawn: no pty sidecar embedded for \{key}; set \{SIDECAR_ENV} to a sidecar built from sidecar/sidecar.c",
    )
  }
  if cached_path(executable) is Some(path) {
    return (path, None)
  }
  // No cache directory: a fresh private directory for this sidecar alone.
  // A predictable path in a shared temporary directory could be planted by
  // another user.
  let dir = @async/fs.tmpdir(prefix="moonbit-pty-sidecar")
  errdefer remove_temp_dir(dir)
  let path = "\{dir}/\{executable_name()}"
  write_executable(path, executable)
  (path, Some(dir))
}

///|
fn executable_name() -> String {
  if @async.platform is Windows {
    "pty-sidecar.exe"
  } else {
    "pty-sidecar"
  }
}

///|
async fn write_executable(path : String, executable : Bytes) -> Unit {
  @async/fs.write_file(
    path,
    executable,
    create_mode=CreateNew,
    permission=0o700,
  )
  if !(@async.platform is Windows) {
    @async/fs.chmod(path, 0o700)
  }
}

///|
/// The embedded sidecar, once it has been found or written in the cache
/// directory by this process.
let cached : Ref[String?] = Ref(None)

///|
/// Distinguishes this process's temporary files in the cache directory.
let temp_counter : Ref[Int32] = Ref(0)

///|
/// The embedded sidecar as an executable in the user's cache directory,
/// named after a hash of its content, written there the first time. Starting
/// the same file again is what keeps spawning cheap: macOS checks every new
/// executable on its first launch, which costs about 300 ms.
///
/// The cache directory belongs to the user, unlike the shared temporary
/// directory, and the file is compared with the embedded bytes before this
/// process first uses it. `None` when there is no cache directory or it
/// cannot be written.
async fn cached_path(executable : Bytes) -> String? {
  if cached.val is Some(path) {
    return Some(path)
  }
  guard cache_root() is Some(root) else { return None }
  let dir = "\{root}/moonbit-pty/sidecar-\{fnv1a64(executable).to_string(radix=16)}"
  let path = "\{dir}/\{executable_name()}"
  let found = try @async/fs.read_file(path).binary() == executable catch {
    _ => false
  }
  if !found {
    try {
      @async/fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true)
      // Written under a name of its own, then renamed into place, so that a
      // process racing with this one never starts a half-written file.
      temp_counter.val += 1
      let temp = "\{path}.\{@env.now()}.\{temp_counter.val}.tmp"
      write_executable(temp, executable)
      @async/fs.rename(temp, path, replace=true) catch {
        error => {
          // Windows cannot replace a running image: another process may
          // have won the race and be running it already.
          @async/fs.remove(temp) catch {
            _ => ()
          }
          guard @async/fs.read_file(path).binary() == executable else {
            raise error
          }
        }
      }
    } catch {
      _ => return None
    }
  }
  cached.val = Some(path)
  Some(path)
}

///|
/// Where per-user caches live: `%LOCALAPPDATA%` on Windows,
/// `~/Library/Caches` on macOS, `$XDG_CACHE_HOME` or `~/.cache` elsewhere.
fn cache_root() -> String? {
  fn non_empty(name : String) -> String? {
    if @env.get_env_var(name) is Some(value) && value != "" {
      Some(value)
    } else {
      None
    }
  }

  match @async.platform {
    Windows => non_empty("LOCALAPPDATA")
    MacOS => non_empty("HOME").map(home => "\{home}/Library/Caches")
    Linux =>
      if non_empty("XDG_CACHE_HOME") is Some(dir) {
        Some(dir)
      } else {
        non_empty("HOME").map(home => "\{home}/.cache")
      }
  }
}

///|
/// 64-bit FNV-1a: names the cache entry after the executable's content.
fn fnv1a64(data : Bytes) -> UInt64 {
  let mut hash = 0xcbf29ce484222325UL
  for b in data {
    hash = (hash ^ b.to_uint64()) * 0x100000001b3UL
  }
  hash
}

///|
/// `ENOTSUP` (Linux 95, macOS 45); Windows has no such code, so the Linux
/// value stands in there.
fn enotsup() -> Int32 {
  if @async.platform is MacOS {
    45
  } else {
    95
  }
}

///|
/// How often `remove_temp_dir` tries on Windows, and how long it sleeps
/// between tries: a running image stays locked until the process has fully
/// terminated, which can be shortly after its pipes closed.
const WINDOWS_RMDIR_ATTEMPTS : Int32 = 10

///|
const WINDOWS_RMDIR_RETRY_MS : Int32 = 50

///|
/// Remove the directory that held the sidecar executable. A directory that
/// still cannot be removed is left behind.
async fn remove_temp_dir(dir : String) -> Unit nocancel {
  let attempts = if @async.platform is Windows {
    WINDOWS_RMDIR_ATTEMPTS
  } else {
    1
  }
  for attempt in 1..<=attempts {
    try @async/fs.rmdir(dir, recursive=true) catch {
      _ if attempt < attempts =>
        @async.protect_from_cancel(() => @async.sleep(WINDOWS_RMDIR_RETRY_MS))
      _ => ()
    } noraise {
      _ => return
    }
  }
}
