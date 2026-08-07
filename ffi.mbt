///|
/// Value-as-Bytes wrapper around the C-side `MoonBitPty` struct: plain POD
/// state in a GC-managed Bytes allocation, no finalizer. OS resources are
/// released explicitly by `Pty::close`, never by GC collection.
priv struct PtyHandle(Bytes)

///|
extern "c" fn PtyHandle::new() -> PtyHandle = "moonbit_pty_new"

///|
#cfg(platform="windows")
#borrow(self, command_line, cwd)
extern "c" fn PtyHandle::spawn(
  self : PtyHandle,
  command_line : String,
  cwd : String,
  has_cwd : Bool,
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
#cfg(platform="windows")
#borrow(self)
extern "c" fn PtyHandle::resize(
  self : PtyHandle,
  cols : Int,
  rows : Int,
) -> Int = "moonbit_pty_resize"

///|
#cfg(not(platform="windows"))
extern "c" fn pty_resize(master_fd : @types.Fd, cols : Int, rows : Int) -> Int = "moonbit_pty_resize"

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
/// Stop the terminal source so an in-flight read can finish normally.
/// Raw read/write handles remain owned by `Pty` until their operations return.
#borrow(self)
extern "c" fn PtyHandle::shutdown(self : PtyHandle) -> Unit = "moonbit_pty_shutdown"

///|
#borrow(self)
extern "c" fn PtyHandle::close(self : PtyHandle) -> Unit = "moonbit_pty_close"
