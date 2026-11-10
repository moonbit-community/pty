///|
/// Sends input to the child's terminal.
/// These are the standard `@async/io.Writer` methods with their usual
/// semantics: `write_once` performs a single write and reports how many
/// bytes were accepted, `write` writes the whole buffer before returning,
/// and `write_reader` forwards everything read from another reader.
pub extend Pty with @async/io.Writer::{write_once, write, write_reader}

///|
/// Reads the child's terminal output (stdout and stderr merged).
/// These are the standard `@async/io.Reader` methods with their usual
/// semantics: `read` reads what is immediately available, `read_some`
/// returns as soon as some data arrives, `read_all` collects until EOF, and
/// `read_until` / `read_exactly` / `drop` behave as documented on
/// `@async/io.Reader`.
///
/// Read concurrently with `Pty::wait` — do not wait for the child and only
/// then read: the output travels through bounded queues, and a child whose
/// output nobody reads blocks writing it, so it never exits.
///
/// On Windows the output is a ConPTY screen rendering rather than a raw
/// byte stream: expect VT escape sequences (including an initial
/// clear-screen) surrounding the child's output.
pub extend Pty with @async/io.Reader::{
  read,
  read_some,
  drop,
  read_all,
  read_until,
  read_exactly,
}

///|
#deprecated("internal")
#doc(hidden)
pub extend Pty with @async/io.Reader::{_direct_read, _get_internal_buffer}

///|
/// A pseudo-terminal attached to a spawned child process.
///
/// `Pty` implements `@async/io.Reader` and `@async/io.Writer`: writes send
/// input to the child's terminal, reads carry the terminal's output (stdout
/// and stderr merged). On Windows the output is a ConPTY screen rendering,
/// so it is wrapped in VT escape sequences (including an initial
/// clear-screen) rather than being the child's raw bytes.
///
/// The terminal is held by a small sidecar process (`sidecar/`) that the
/// library starts for each pty and talks to over pipes, which is what lets
/// the same implementation run on the native and wasm targets.
///
/// The pty's resources are released when the task group passed to `spawn`
/// exits. If the group is cancelled, the child gets a 5 s grace period,
/// then a hard kill.
struct Pty {
  sidecar : @sidecar.Sidecar
  result : @async.Task[Int32]
}

///|
/// Spawns a child process attached to a new pseudo-terminal and returns the
/// `Pty` handle.
///
/// The child runs `file` with `args` as its arguments; its `argv[0]` is
/// `file` verbatim, so programs that dispatch on `argv[0]` (busybox-style
/// multi-call binaries, shells checking for a leading `-`) see what the
/// caller wrote. `file` is looked up through `PATH` when it does not contain
/// a path separator, and used directly otherwise.
///
/// * `rows` and `cols` set the initial terminal size in characters.
/// * `extra_env` adds or overrides environment variables; by default
///   (`inherit_env=true`) the child also inherits the current process's
///   environment.
/// * `cwd` sets the child's working directory; by default the child starts
///   in the current directory.
/// * `no_wait` has the same semantics as `@async/process.spawn`: by default
///   the task group waits for the child to terminate; with `no_wait=true`
///   the group exits as soon as its own tasks are done, terminating the
///   child.
///
/// The returned `Pty` implements `@async/io.Reader` and `@async/io.Writer`,
/// and its resources are released when `group` exits. Raises
/// `@os_error.OSError` if the pty cannot be opened or the child cannot be
/// spawned.
pub async fn[X] spawn(
  group : @async.TaskGroup[X],
  rows~ : Int32 = 24,
  cols~ : Int32 = 80,
  file : StringView,
  args : ArrayView[StringView],
  extra_env~ : Map[String, String] = Map([]),
  inherit_env~ : Bool = true,
  cwd? : StringView,
  no_wait? : Bool,
) -> Pty {
  let request = match @async.platform {
    Windows =>
      windows_spawn_request(
        rows~,
        cols~,
        file~,
        args~,
        extra_env~,
        inherit_env~,
        cwd~,
      )
    Linux | MacOS =>
      unix_spawn_request(
        rows~,
        cols~,
        file~,
        args~,
        extra_env~,
        inherit_env~,
        cwd~,
      )
  }
  let sidecar = @sidecar.Sidecar::spawn(request)
  group.add_defer(() => sidecar.close())
  let result = group.spawn(no_wait?) <| () => {
    if @async.handle_cancellation(() => sidecar.wait()) is Some(status) {
      status
    } else {
      // Cancelled: end the child anyway (close its terminal, give it the
      // grace period, then kill it) and complete with its exit status, like
      // `@async/process.spawn` does. `try ... catch` no longer observes
      // cancellation (async 0.22), so this match is the only thing that
      // makes the cleanup run at all.
      @async.protect_from_cancel() <| () => {
        wait_with(() => sidecar.wait()) <| () => {
          // Stop reading the output first: the sidecar then drains it into
          // the void, so neither the child nor ConPTY's teardown can block
          // on a full pipe nobody reads (docs/invariants.md).
          sidecar.close_output()
          sidecar.hangup() catch {
            _ => ()
          }
          @async.sleep(GRACE_PERIOD_MS)
          sidecar.kill() catch {
            _ => ()
          }
        }
      }
    }
  }
  { sidecar, result, }
}

///|
/// Grace period between hanging up a cancelled child's terminal and killing
/// it; matches the ~5 s Windows itself grants on CTRL_CLOSE_EVENT. The
/// sidecar applies the same period when its parent goes away
/// (`GRACE_MS` in sidecar/sidecar.c).
const GRACE_PERIOD_MS : Int32 = 5000

///|
/// Waits for the child process to terminate and returns its exit code.
/// If the process was killed by a signal, the result is `-signal_number`
/// (the same convention as `@async/process.wait_pid`).
///
/// Read concurrently while waiting rather than waiting first: the output
/// travels through a bounded pipe, and a child whose output nobody reads
/// eventually blocks writing it.
pub async fn Pty::wait(self : Pty) -> Int32 {
  self.result.wait()
}

///|
/// The process ID of the spawned child process.
pub fn Pty::pid(self : Pty) -> Int32 {
  self.sidecar.child_pid()
}

///|
/// Resizes the child's terminal, in characters.
/// Raises `@os_error.OSError` if the resize fails, including when the pty
/// has already been closed (for example after the owning task group has
/// exited).
pub async fn Pty::resize(self : Pty, rows~ : Int32, cols~ : Int32) -> Unit {
  self.sidecar.resize(rows~, cols~)
}

///|
#warnings("-alert_internal")
pub impl @async/io.Reader for Pty with fn _get_internal_buffer(self : Pty) -> @async/io.ReaderBuffer {
  @async/io.Reader::_get_internal_buffer(self.sidecar.output())
}

///|
pub impl @async/io.Reader for Pty with fn _direct_read(
  self : Pty,
  buf : FixedArray[Byte],
  offset~ : Int32,
  max_len~ : Int32,
) -> Int32 {
  @async/io.Reader::_direct_read(self.sidecar.output(), buf, offset~, max_len~)
}

///|
pub impl @async/io.Writer for Pty with fn write_once(
  self : Pty,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  self.sidecar.write_once(buf, offset~, len~)
}

///|
// Run `waiter` (which waits for the child's exit) while `background` runs
// alongside (close the terminal, grace period, hard kill, ...). The waiter is
// a spawned task on purpose, never the main task of the group: if the runtime
// cancels the waiter directly (`EventLoop::cleanup` after a fatal error in the
// host event loop), the group fails with `@async.WaitedTaskAlreadyCancelled`
// instead of reaching `with_task_group`'s `result.unwrap()` on a `Done` group
// with no result, which aborts the whole process (moonbitlang/async
// task_group.mbt:270 as of 0.22.4). See docs/invariants.md; pty_wbtest.mbt
// guards it. The waiter is spawned first so that it is already waiting
// before `background` starts tearing the terminal down.
//
// `on_waiter` is a test hook (pty_wbtest.mbt): it hands out the waiter task
// so a test can cancel it the way the runtime would. Only that whitebox test
// supplies it, so silence unused_optional_argument.
#warnings("-unused_optional_argument")
async fn wait_with(
  waiter : async () -> Int32,
  background : async () -> Unit,
  on_waiter? : (@async.Task[Int32]) -> Unit,
) -> Int32 {
  @async.with_task_group() <| g => {
    let waiter = g.spawn(waiter)
    if on_waiter is Some(hook) {
      hook(waiter)
    }
    g.spawn_bg(no_wait=true, background)
    waiter.wait()
  }
}

///|
/// Spawns a child process attached to a new pseudo-terminal, runs `f` with
/// its `Pty`, and releases the pty when `f` is done.
///
/// The pty lives exactly as long as `f`. When `f` returns, raises, or is
/// cancelled, the terminal is closed; a child that is still running is hung
/// up, given the 5 s grace period, then killed, and `with_pty` only returns
/// once it has been reaped. Call `Pty::wait` inside `f` to let the child
/// finish on its own and to get its exit code.
///
/// Prefer this over `spawn` when the pty's lifetime is a lexical scope and
/// no task group with that lifetime exists yet: `spawn` keeps the pty open
/// until its task group exits, so a long-lived group that spawns many ptys
/// accumulates their file descriptors.
///
/// `rows`, `cols`, `file`, `args`, `extra_env`, `inherit_env` and `cwd` are
/// those of `spawn`, with the same defaults.
///
/// Do not let the `Pty` escape `f`: it is closed afterwards, and a task
/// still blocked reading it is not woken up. When tasks need to read or
/// write the pty concurrently, open a task group for them and `spawn` the
/// pty into that group directly, rather than nesting one inside `with_pty`.
pub async fn[T] with_pty(
  rows? : Int32,
  cols? : Int32,
  file : StringView,
  args : ArrayView[StringView],
  extra_env? : Map[String, String],
  inherit_env? : Bool,
  cwd? : StringView,
  f : async (Pty) -> T,
) -> T {
  // `no_wait=true`: once `f` is done nobody reads the terminal any more, so
  // waiting for the child could block forever on a full pty queue. The group
  // cancels the wait task instead, which runs the usual cancellation cleanup.
  @async.with_task_group() <| group => {
    f(
      spawn(
        group,
        rows?,
        cols?,
        file,
        args,
        extra_env?,
        inherit_env?,
        cwd?,
        no_wait=true,
      ),
    )
  }
}
