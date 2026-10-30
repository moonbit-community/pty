///|
// The same table as the `test "get_path_candidates"` block in `pty_unix.mbt`
// (the native copy of the rule): the two have to resolve identically (see
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
