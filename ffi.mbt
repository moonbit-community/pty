///|
priv type PtyHandle

///|
#cfg(platform="windows")
#borrow(argv_flat)
extern "c" fn pty_spawn_windows(
  argv_flat : Bytes,
  cols : Int,
  rows : Int,
) -> PtyHandle = "moonbit_pty_spawn_windows"

///|
#cfg(not(platform="windows"))
extern "c" fn pty_failure(errno : Int) -> PtyHandle = "moonbit_pty_failure"

///|
#cfg(not(platform="windows"))
extern "c" fn pty_open(cols : Int, rows : Int) -> PtyHandle = "moonbit_pty_open"

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
/// Returns the OS error captured during `pty_spawn` (0 = success).
/// The value is `errno` on Unix / `GetLastError()` on Windows.
#borrow(handle)
extern "c" fn pty_check_spawn(handle : PtyHandle) -> Int = "moonbit_pty_check_spawn"

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
