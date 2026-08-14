///|
struct Handle(@async/types.Fd)

///|
pub impl Eq for Handle with fn equal(self : Handle, other : Handle) -> Bool {
  Eq::equal(self.0, other.0)
}

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

///|
pub async fn Handle::to_raw_fd_stream(
  self : Handle,
) -> @async/raw_fd.RawFdStream {
  @async/raw_fd.RawFdStream(self.0)
}

///|
/// `Fd` is an opaque `#external` pointer type on win32, so the invalid value
/// (INVALID_HANDLE_VALUE) can only be produced by the C side.
#cfg(platform="windows")
pub extern "c" fn Handle::invalid() -> Handle = "moonbit_pty_win32_get_invalid_handle"

///|
/// The conventional invalid value on both platforms (-1 on unix,
/// INVALID_HANDLE_VALUE on win32); used as the placeholder in out-parameter
/// arrays the C side fills in.
#cfg(not(platform="windows"))
pub fn Handle::invalid() -> Handle {
  Handle(-1)
}

///|
pub fn borrow_raw_fd_stream(
  raw_fd_stream : @async/raw_fd.RawFdStream,
) -> Handle {
  Handle(raw_fd_stream.fd)
}
