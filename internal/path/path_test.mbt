///|
// The same table as `pty_unix_test.mbt` in the root package: the native and
// wasm copies of the PATH rule have to resolve identically (see
// docs/invariants.md).
test "get_path_candidates" {
  assert_eq(@path.get_path_candidates(file="sh", path="/usr/bin:/bin"), [
    b"/usr/bin/sh", b"/bin/sh",
  ])
  assert_eq(
    @path.get_path_candidates(file="/usr/bin/sh", path="/bin:/usr/bin"),
    [b"/usr/bin/sh"],
  )
  assert_eq(@path.get_path_candidates(file="./relative", path="/bin"), [
    b"./relative",
  ])
  assert_eq(
    @path.get_path_candidates(file="nosuchprog", path="/usr/bin:/bin"),
    [b"/usr/bin/nosuchprog", b"/bin/nosuchprog"],
  )
  // Empty entries — leading, trailing, doubled, or the whole PATH — yield no
  // candidate; "." is an ordinary entry and is kept.
  assert_eq(@path.get_path_candidates(file="sh", path=""), [])
  assert_eq(@path.get_path_candidates(file="sh", path=":"), [])
  assert_eq(@path.get_path_candidates(file="sh", path=":/bin"), [b"/bin/sh"])
  assert_eq(@path.get_path_candidates(file="sh", path="/bin:"), [b"/bin/sh"])
  assert_eq(@path.get_path_candidates(file="sh", path="/usr/bin::/bin"), [
    b"/usr/bin/sh", b"/bin/sh",
  ])
  assert_eq(@path.get_path_candidates(file="sh", path=".:/bin"), [
    b"./sh", b"/bin/sh",
  ])
}
