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
/// then read: the pty master is a bounded kernel queue, and on macOS the
/// kernel discards whatever is still queued a few hundred milliseconds after
/// the child exits. Reading late yields a clean but empty EOF.
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
// Wait for `pid` while `background` runs alongside (close the terminal, grace
// period, hard kill, ...). The waiter is a spawned task on purpose, never the
// main task of the group: if the runtime cancels the waiter directly
// (`EventLoop::cleanup` after a fatal error in the host event loop), the
// group fails with `@async.WaitedTaskAlreadyCancelled` instead of reaching
// `with_task_group`'s `result.unwrap()` on a `Done` group with no result,
// which aborts the whole process (moonbitlang/async task_group.mbt:270 as of
// 0.22.4). See docs/invariants.md; pty_wbtest.mbt guards it.
// The waiter is spawned first so that it registers for the child before
// `background` starts tearing the terminal down.
//
// `on_waiter` is a test hook (pty_wbtest.mbt): it hands out the waiter task
// so a test can cancel it the way the runtime would. Only that whitebox test
// supplies it, so silence unused_optional_argument.
#warnings("-unused_optional_argument")
async fn wait_pid_with(
  pid : Int32,
  background : async () -> Unit,
  on_waiter? : (@async.Task[Int32]) -> Unit,
) -> Int32 {
  @async.with_task_group() <| g => {
    let waiter = g.spawn(() => @async/process.wait_pid(pid))
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
