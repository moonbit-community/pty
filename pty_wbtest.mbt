///|
// Guards the cancellation-cleanup shape recorded in docs/invariants.md.
// When the runtime cancels the waiter directly (what `EventLoop::cleanup`
// does to every fd/pid waiter after a fatal error in the host event loop),
// `wait_with` must fail with `@async.WaitedTaskAlreadyCancelled` instead of
// reaching `with_task_group`'s `result.unwrap()` on a `Done` group with no
// result, which aborts the whole process. `Task::cancel` is the same
// `Coroutine::cancel` the runtime uses, so the hook reproduces that condition
// exactly; the old shape (waiting in the group's main task) has no task to
// hand out and would abort here. The sleep stands in for the sidecar's event
// read the real waiter is blocked in.
async test "wait_with: waiter cancelled by the runtime raises WaitedTaskAlreadyCancelled" {
  let waiter : Ref[@async.Task[Int32]?] = Ref(None)
  try
    wait_with(
      () => {
        @async.sleep(10000)
        0
      },
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
async test "wait_with: returns the waiter's result" {
  assert_eq(
    wait_with(
      () => {
        @async.sleep(10)
        7
      },
      () => (),
    ),
    7,
  )
}
