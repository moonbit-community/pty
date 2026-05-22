///|
priv type PtyHandle

///|
extern "c" fn pty_new() -> PtyHandle = "moonbit_pty_new"

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
#borrow(handle, argv_flat)
extern "c" fn pty_spawn_windows(
  handle : PtyHandle,
  argv_flat : Bytes,
  cols : Int,
  rows : Int,
) -> Int = "moonbit_pty_spawn_windows"

///|
#cfg(not(platform="windows"))
#borrow(handle)
extern "c" fn pty_open(handle : PtyHandle, cols : Int, rows : Int) -> Int = "moonbit_pty_open"

///|
#cfg(not(platform="windows"))
#borrow(handle)
extern "c" fn pty_bind_slave_to_fd(handle : PtyHandle, fd : @types.Fd) -> Int = "moonbit_pty_bind_slave_to_fd"

///|
#cfg(not(platform="windows"))
#borrow(handle)
extern "c" fn pty_set_child_pid(handle : PtyHandle, pid : Int) -> Unit = "moonbit_pty_set_child_pid"

///|
#cfg(not(platform="windows"))
#borrow(data)
extern "c" fn pty_decode_child_error(data : Bytes) -> Int = "moonbit_pty_decode_child_error"

///|
#cfg(not(platform="windows"))
extern "c" fn pty_self_executable() -> Bytes = "moonbit_pty_self_executable"

///|
#cfg(not(platform="windows"))
extern "c" fn pty_self_args_flat() -> Bytes = "moonbit_pty_self_args_flat"

///|
#borrow(handle)
extern "c" fn pty_resize(handle : PtyHandle, cols : Int, rows : Int) -> Int = "moonbit_pty_resize"

///|
#borrow(handle)
extern "c" fn pty_take_read_fd(handle : PtyHandle) -> @types.Fd = "moonbit_pty_take_read_fd"

///|
#cfg(platform="windows")
#borrow(handle)
extern "c" fn pty_take_write_fd_windows(handle : PtyHandle) -> @types.Fd = "moonbit_pty_take_write_fd_windows"

///|
#cfg(platform="windows")
extern "c" fn pty_kill_pid_windows(pid : Int) -> Unit = "moonbit_pty_kill_pid_windows"

///|
#borrow(handle)
extern "c" fn pty_child_pid(handle : PtyHandle) -> Int = "moonbit_pty_child_pid"

///|
#borrow(handle)
extern "c" fn pty_close(handle : PtyHandle) -> Unit = "moonbit_pty_close"
