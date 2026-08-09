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
#cfg(platform="windows")
extern "c" fn Handle::null() -> Handle = "moonbit_pty_internal_handle_win32_get_null"

///|
#cfg(platform="windows")
pub let null : Handle = Handle::null()

///|
#cfg(platform="windows")
pub extern "c" fn Handle::close(self : Handle) -> Unit = "CloseHandle"

///|
#cfg(not(platform="windows"))
pub extern "c" fn Handle::close(self : Handle) -> Unit = "close"
