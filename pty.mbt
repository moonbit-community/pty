///|
pub extend Pty with @async/io.Writer::{write_once, write, write_reader}

///|
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
// group fails with `Cancelled` instead of reaching `with_task_group`'s
// `result.unwrap()` on a `Done` group with no result, which aborts the whole
// process (moonbitlang/async task_group.mbt:268). See repro/ for both shapes.
// The waiter is spawned first so that it registers for the child before
// `background` starts tearing the terminal down.
//
// `on_waiter` is a test hook (pty_wbtest.mbt): it hands out the waiter task
// so a test can cancel it the way the runtime would.
async fn wait_pid_with(
  pid : Int,
  background : async () -> Unit,
  on_waiter? : (@async.Task[Int]) -> Unit,
) -> Int {
  @async.with_task_group() <| g => {
    let waiter = g.spawn(() => @async/process.wait_pid(pid))
    if on_waiter is Some(hook) {
      hook(waiter)
    }
    g.spawn_bg(no_wait=true, background)
    waiter.wait()
  }
}
