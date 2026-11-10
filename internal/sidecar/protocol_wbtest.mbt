///|
test "SpawnRequest::encode lays out the SPAWN frame" {
  let frame = SpawnRequest::{
    rows: 24,
    cols: 80,
    candidates: ["/bin/sh"],
    argv: ["sh", "-c"],
    env: [],
    cwd: Some("/tmp"),
  }.encode()
  guard frame[:] is [tag, u32le(len), .. payload] else { fail("short frame") }
  assert_eq(tag, CMD_SPAWN)
  assert_eq(len.reinterpret_as_int(), payload.length())
  assert_eq(
    payload.to_owned(),
    b"\x01\x00\x00\x00\x18\x00\x50\x00" +
    b"\x01\x00\x00\x00\x07\x00\x00\x00/bin/sh" +
    b"\x02\x00\x00\x00\x02\x00\x00\x00sh\x02\x00\x00\x00-c" +
    b"\x00\x00\x00\x00" +
    b"\x01\x00\x00\x00\x04\x00\x00\x00/tmp",
  )
}

///|
test "encode_resize" {
  assert_eq(encode_resize(31, 113), b"\x03\x04\x00\x00\x00\x1f\x00\x71\x00")
}

///|
test "fnv1a64 matches the reference vectors" {
  assert_eq(fnv1a64(b""), 0xcbf29ce484222325UL)
  assert_eq(fnv1a64(b"a"), 0xaf63dc4c8601ec8cUL)
  assert_eq(fnv1a64(b"foobar"), 0x85944171f73967e8UL)
}
