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

///|
// Guards what `with_pty` exists for: a session must give its descriptors
// back when it ends, not when some enclosing task group does. The kernel
// hands out the lowest free descriptor number, so sessions that release
// their pty keep getting (nearly) the same number back, while a leak climbs
// by at least one per session — 50 sessions against a bound of 8 leaves no
// room to confuse the two.
async test "with_pty: sessions do not accumulate file descriptors" {
  guard !(@async.platform is Windows) else { return }
  // The lowest free descriptor once a session is over, probed with a pipe.
  async fn session_fd() -> Int64 {
    with_pty("true", [], pty => ignore(pty.read_all()))
    let (r, w) = @async/pipe.pipe()
    let fd = descriptor_number(r)
    r.close()
    w.close()
    fd
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

///|
// The descriptor number behind `r`, for the leak test above. `fd()` is the
// descriptor (`Int32`) on native Unix. On wasm it is moonrun's `UInt64`
// handle: a generation in the high 32 bits and a reused slot in the low 32,
// and the slot behaves like the lowest free descriptor. Both print as
// decimal digits.
//
// The one `#cfg` left in the tests, for a type rather than a behavior: on
// Windows native `Fd` is an opaque HANDLE with no number to read, and the
// leak test returns before calling this.
#cfg(not(platform="windows"))
fn descriptor_number(r : @async/pipe.PipeRead) -> Int64 {
  let n = r
    .fd()
    .to_string()
    .fold(init=0L, (n, c) => n * 10 + (c.to_int() - '0'.to_int()).to_int64())
  n & 0xFFFF_FFFFL
}

///|
#cfg(platform="windows")
fn descriptor_number(_r : @async/pipe.PipeRead) -> Int64 {
  abort("@pty test: descriptor numbers are not observable on Windows")
}
