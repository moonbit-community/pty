///|
// Guards the cancellation-cleanup shape recorded in docs/invariants.md.
// When the runtime cancels the `wait_pid` waiter directly (what
// `EventLoop::cleanup` does to every fd/pid waiter after a fatal error in the
// host event loop), `wait_pid_with` must fail with `@async.WaitedTaskAlreadyCancelled`
// instead of reaching `with_task_group`'s `result.unwrap()` on a `Done` group
// with no result, which aborts the whole process. `Task::cancel` is the same
// `Coroutine::cancel` the runtime uses, so the hook reproduces that condition
// exactly; the old shape (waiting in the group's main task) has no task to
// hand out and would abort here.
#cfg(not(platform="windows"))
async test "wait_pid_with: waiter cancelled by the runtime raises WaitedTaskAlreadyCancelled" {
  // Outlives the cancellation; nobody reaps it afterwards and the zombie is
  // collected when the test binary exits.
  let pid = @async/process.spawn_orphan("sleep", ["1"])
  let waiter : Ref[@async.Task[Int]?] = Ref(None)
  try
    wait_pid_with(
      pid,
      () => {
        @async.sleep(50)
        waiter.val.unwrap().cancel()
      },
      on_waiter=t => waiter.val = Some(t),
    )
  catch {
    @async.WaitedTaskAlreadyCancelled => ()
    error => fail("expected @async.WaitedTaskAlreadyCancelled, got \{error}")
  } noraise {
    status =>
      fail(
        "expected @async.WaitedTaskAlreadyCancelled, got exit status \{status}",
      )
  }
  // The cancellation came from the waiter, not from this task.
  assert_false(@async.is_being_cancelled())
}

///|
#cfg(not(platform="windows"))
async test "wait_pid_with: returns the child's exit status" {
  let pid = @async/process.spawn_orphan("sh", ["-c", "exit 7"])
  assert_eq(wait_pid_with(pid, () => ()), 7)
}

///|
// Guards what `with_pty` exists for: a session must give its descriptors
// back when it ends, not when some enclosing task group does. The kernel
// hands out the lowest free descriptor number, so sessions that release
// their pty keep getting (nearly) the same number back, while a leak climbs
// by at least one per session — 50 sessions against a bound of 8 leaves no
// room to confuse the two.
#cfg(not(platform="windows"))
async test "with_pty: sessions do not accumulate file descriptors" {
  async fn session_fd() -> Int {
    with_pty("true", [], pty => {
      pty.read_all() |> ignore()
      pty.primary.fd
    })
  }
  let first = session_fd()
  let mut highest = first
  for _ in 0..<50 {
    let fd = session_fd()
    if fd > highest {
      highest = fd
    }
  }
  assert_true(highest - first < 8)
}
