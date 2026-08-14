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
pub async fn Handle::to_raw_fd_stream(self : Handle) -> @async/raw_fd.RawFdStream {
  @async/raw_fd.RawFdStream(self.0)
}
