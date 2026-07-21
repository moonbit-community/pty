///|
priv type PtyHandle

///|
extern "c" fn PtyHandle::new() -> PtyHandle = "moonbit_pty_new"

///|
/// Set the platform's last OS error to "invalid argument" and return -1.
///
/// Some argument errors are detected in MoonBit before we call a syscall, so
/// there is no fresh errno/GetLastError value for `@os_error.check_errno` to
/// read. This shim lets those errors use the same 0/-1 + check_errno path as
/// real native calls without hardcoding POSIX errno values on Windows.
extern "c" fn pty_set_invalid_argument() -> Int = "moonbit_pty_set_invalid_argument"

///|
#cfg(platform="windows")
#borrow(self, command_line)
extern "c" fn PtyHandle::spawn(
  self : PtyHandle,
  command_line : Bytes,
  cols : Int,
  rows : Int,
) -> Int = "moonbit_pty_spawn"

///|
#cfg(not(platform="windows"))
#borrow(self)
extern "c" fn PtyHandle::open(self : PtyHandle, cols : Int, rows : Int) -> Int = "moonbit_pty_open"

///|
#cfg(not(platform="windows"))
#borrow(self)
extern "c" fn PtyHandle::bind_slave_to_fd(
  self : PtyHandle,
  fd : @types.Fd,
) -> Int = "moonbit_pty_bind_slave_to_fd"

///|
#cfg(not(platform="windows"))
#borrow(self)
extern "c" fn PtyHandle::set_child_pid(self : PtyHandle, pid : Int) -> Unit = "moonbit_pty_set_child_pid"

///|
#cfg(not(platform="windows"))
extern "c" fn pty_self_executable() -> Bytes = "moonbit_pty_self_executable"

///|
#cfg(not(platform="windows"))
extern "c" fn pty_self_args_flat() -> Bytes = "moonbit_pty_self_args_flat"

///|
#borrow(self)
extern "c" fn PtyHandle::resize(
  self : PtyHandle,
  cols : Int,
  rows : Int,
) -> Int = "moonbit_pty_resize"

///|
#borrow(self)
extern "c" fn PtyHandle::take_read_fd(self : PtyHandle) -> @types.Fd = "moonbit_pty_take_read_fd"

///|
#cfg(platform="windows")
#borrow(self)
extern "c" fn PtyHandle::take_write_fd(self : PtyHandle) -> @types.Fd = "moonbit_pty_take_write_fd"

///|
#cfg(platform="windows")
extern "c" fn pty_kill_pid(pid : Int) -> Unit = "moonbit_pty_kill_pid"

///|
#borrow(self)
extern "c" fn PtyHandle::child_pid(self : PtyHandle) -> Int = "moonbit_pty_child_pid"

///|
#borrow(self)
extern "c" fn PtyHandle::close(self : PtyHandle) -> Unit = "moonbit_pty_close"
