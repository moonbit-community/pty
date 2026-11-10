///|
/// Frame protocol spoken with `sidecar/sidecar.c`, see `sidecar/README.md`.
/// Every frame is `tag:u8 len:u32le payload`. Commands go to the sidecar's
/// stdin, events come back on its stderr; its stdout carries the terminal's
/// output unframed.
const PROTOCOL_VERSION : UInt32 = 1

///|
const CMD_SPAWN : Byte = 0x01

///|
const CMD_WRITE : Byte = 0x02

///|
const CMD_RESIZE : Byte = 0x03

///|
const CMD_HANGUP : Byte = 0x04

///|
const CMD_KILL : Byte = 0x05

///|
const EV_SPAWNED : Byte = 0x80

///|
const EV_SPAWN_FAILED : Byte = 0x81

///|
const EV_WROTE : Byte = 0x82

///|
const EV_WRITE_FAILED : Byte = 0x83

///|
const EV_RESIZED : Byte = 0x84

///|
const EV_EXIT : Byte = 0x85

///|
const EV_FAILED : Byte = 0x86

///|
const HEADER_SIZE : Int32 = 5

///|
/// Largest event payload accepted; the sidecar never sends more than a short
/// message, so anything beyond this is a corrupt stream.
const MAX_EVENT : Int32 = 64 * 1024

///|
/// What the sidecar reports.
priv enum Event {
  /// The child is running; its pid.
  Spawned(Int32)
  /// The child could not be started; the OS error code.
  SpawnFailed(Int32)
  /// This many bytes of earlier WRITE commands reached the terminal.
  Wrote(Int32)
  /// Writing to the terminal failed; queued input was dropped.
  WriteFailed(Int32)
  /// Reply to one RESIZE command, in order; 0 on success.
  Resized(Int32)
  /// The child was reaped: its exit code, or `-signal`.
  Exit(Int32)
  /// The sidecar itself failed.
  Failed(Int32, String)
}

///|
/// The sidecar sent something that is not a well-formed event, or went away
/// without reporting what it was asked about.
pub suberror SidecarError {
  SidecarError(String)
}

///|
pub extend SidecarError with Show::{output, to_string}

///|
pub impl Show for SidecarError with fn output(self, logger) {
  let SidecarError(message) = self
  logger.write_string("@pty: \{message}")
}

///|
/// Event decoder over the sidecar's stderr.
///
/// Incoming bytes are accumulated in `buf` and frames are cut from there, so a
/// read that is cancelled can only ever lose a read that had not returned yet;
/// a header or partial payload already received stays in the buffer.
priv struct EventReader {
  reader : @async/process.ReadFromProcess
  mut buf : FixedArray[Byte]
  mut len : Int32
}

///|
fn EventReader::new(reader : @async/process.ReadFromProcess) -> EventReader {
  { reader, buf: FixedArray::make(256, b'\x00'), len: 0, }
}

///|
/// Make sure at least `needed` bytes are buffered. Returns `false` on a clean
/// EOF before the first byte of a frame, raises on EOF inside one.
async fn EventReader::fill(self : EventReader, needed : Int32) -> Bool {
  if self.buf.length() < needed {
    let grown = FixedArray::make(needed, b'\x00')
    self.buf.blit_to(grown, len=self.len)
    self.buf = grown
  }
  while self.len < needed {
    let n = self.reader.read(
      self.buf,
      offset=self.len,
      max_len=self.buf.length() - self.len,
    )
    if n == 0 {
      if self.len == 0 {
        return false
      }
      raise SidecarError("the sidecar closed its event pipe mid-frame")
    }
    self.len += n
  }
  true
}

///|
/// Next event, `None` once the sidecar has closed its event pipe.
async fn EventReader::next(self : EventReader) -> Event? {
  guard self.fill(HEADER_SIZE) else { return None }
  guard self.buf[:HEADER_SIZE] is [tag, u32le(len)] else {
    raise SidecarError("malformed event header")
  }
  guard len <= MAX_EVENT.reinterpret_as_uint() else {
    raise SidecarError("event length \{len} out of range")
  }
  let len = len.reinterpret_as_int()
  guard self.fill(HEADER_SIZE + len) else {
    raise SidecarError("the sidecar closed its event pipe mid-frame")
  }
  let payload = Bytes::from_array(self.buf[HEADER_SIZE:HEADER_SIZE + len])
  let rest = self.len - HEADER_SIZE - len
  self.buf.blit_to(self.buf, len=rest, src_offset=HEADER_SIZE + len)
  self.len = rest
  let event = match (tag, payload[:]) {
    (EV_SPAWNED, [i32le(v)]) => Spawned(v)
    (EV_SPAWN_FAILED, [i32le(v)]) => SpawnFailed(v)
    (EV_WROTE, [i32le(v)]) => Wrote(v)
    (EV_WRITE_FAILED, [i32le(v)]) => WriteFailed(v)
    (EV_RESIZED, [i32le(v)]) => Resized(v)
    (EV_EXIT, [i32le(v)]) => Exit(v)
    (EV_FAILED, [i32le(code), .. what]) =>
      Failed(code, @encoding/utf8.decode_lossy(what))
    (tag, _) => raise SidecarError("malformed event with tag \{tag}")
  }
  Some(event)
}

///|
fn encode_frame(tag : Byte, payload : BytesView) -> Bytes {
  let buf = @buffer.Buffer(size_hint=HEADER_SIZE + payload.length())
  buf.write_byte(tag)
  buf.write_uint_le(payload.length().reinterpret_as_uint())
  buf.write_bytes(payload)
  buf.contents()
}

///|
fn write_string(buf : @buffer.Buffer, s : StringView) -> Unit {
  let bytes = @encoding/utf8.encode(s)
  buf.write_uint_le(bytes.length().reinterpret_as_uint())
  buf.write_bytes(bytes)
}

///|
fn write_strings(buf : @buffer.Buffer, strings : ArrayView[String]) -> Unit {
  buf.write_uint_le(strings.length().reinterpret_as_uint())
  for s in strings {
    write_string(buf, s)
  }
}

///|
/// How the sidecar should start the child.
///
/// On Unix `argv` is the child's argv and `candidates` are tried in order
/// with `execve`. On Windows `argv` holds exactly one element, the command
/// line, and the first candidate that exists (after `GetFullPathNameW`) is
/// passed to `CreateProcessW` as the application name. `env` is the child's
/// whole environment as `KEY=VALUE` entries. `cwd` is the child's working
/// directory, `None` for the parent's.
pub(all) struct SpawnRequest {
  rows : Int32
  cols : Int32
  candidates : Array[String]
  argv : Array[String]
  env : Array[String]
  cwd : String?
}

///|
fn SpawnRequest::encode(self : SpawnRequest) -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_uint_le(PROTOCOL_VERSION)
  buf.write_uint16_le(self.rows.to_uint16())
  buf.write_uint16_le(self.cols.to_uint16())
  write_strings(buf, self.candidates)
  write_strings(buf, self.argv)
  write_strings(buf, self.env)
  let cwd = if self.cwd is Some(cwd) { [cwd] } else { [] }
  write_strings(buf, cwd)
  encode_frame(CMD_SPAWN, buf.contents())
}

///|
fn encode_resize(rows : Int32, cols : Int32) -> Bytes {
  let buf = @buffer.Buffer(size_hint=4)
  buf.write_uint16_le(rows.to_uint16())
  buf.write_uint16_le(cols.to_uint16())
  encode_frame(CMD_RESIZE, buf.contents())
}
