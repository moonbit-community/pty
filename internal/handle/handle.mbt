///|
struct Handle(@async/types.Fd)

///|
pub impl Eq for Handle with fn equal(self : Handle, other : Handle) -> Bool {
  Eq::equal(self.0, other.0)
}

///|
pub extend Handle with Eq::{equal, not_equal}

///|
#cfg(platform="windows")
extern "c" fn handle_close(handle : Handle) -> Int = "CloseHandle"

///|
#cfg(not(platform="windows"))
extern "c" fn handle_close(handle : Handle) -> Int = "close"

///|
/// Closes the underlying file descriptor (unix) or handle (win32).
///
/// This is a bare `close(2)` / `CloseHandle`: closing twice would hit
/// whatever unrelated descriptor has been handed the recycled number in
/// between, so callers must guard against double closes themselves.
pub fn Handle::close(self : Handle) -> Unit {
  handle_close(self) |> ignore()
}

///|
/// Wraps the handle in a `@async/raw_fd.RawFdStream` for asynchronous reads
/// and writes.
pub async fn Handle::to_raw_fd_stream(
  self : Handle,
) -> @async/raw_fd.RawFdStream {
  RawFdStream(self.0)
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
/// Recovers the `Handle` behind a `RawFdStream` without taking ownership of
/// the descriptor.
pub fn borrow_raw_fd_stream(
  raw_fd_stream : @async/raw_fd.RawFdStream,
) -> Handle {
  Handle(raw_fd_stream.fd)
}
