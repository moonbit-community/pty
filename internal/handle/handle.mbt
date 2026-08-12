///|
pub(all) struct Handle(@async/types.Fd)

///|
pub impl Eq for Handle with fn equal(self : Handle, other : Handle) -> Bool {
  Eq::equal(self.0, other.0)
}

///|
#cfg(platform="windows")
extern "c" fn Handle::invalid() -> Handle = "moonbit_pty_internal_handle_win32_get_invalid_handle_value"

///|
#cfg(platform="windows")
pub let invalid : Handle = Handle::invalid()

///|
#cfg(not(platform="windows"))
pub let invalid : Handle = abort("@handle.invalid is only available on Windows")

///|
#cfg(platform="windows")
extern "c" fn handle_close(handle : Handle) -> Int = "CloseHandle"

///|
#cfg(not(platform="windows"))
extern "c" fn handle_close(handle : Handle) -> Int = "close"

///|
pub fn Handle::close(self : Handle) -> Unit {
  handle_close(self) |> ignore()
}
