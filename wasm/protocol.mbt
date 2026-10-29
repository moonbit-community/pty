///|
/// Frames spoken with `sidecar/sidecar.c`. Every frame is
/// `tag:u8 len:u32le payload`; the payload layout of each tag is documented
/// in docs/internals.md.
const TAG_SPAWN : Byte = b'\x01'

///|
const TAG_WRITE : Byte = b'\x02'

///|
const TAG_RESIZE : Byte = b'\x03'

///|
const TAG_HELLO : Byte = b'\x80'

///|
const TAG_OUTPUT : Byte = b'\x81'

///|
const TAG_EXIT : Byte = b'\x82'

///|
const TAG_ERROR : Byte = b'\x83'

///|
/// Largest payload accepted from the sidecar; it never sends more than its
/// own 4 KiB read buffer, so anything beyond this is corruption.
const MAX_PAYLOAD : Int32 = 1 << 20

///|
/// Largest payload sent in one frame. The sidecar parses commands out of a
/// 64 KiB buffer, so a frame has to stay well below that; `write_once` splits.
const MAX_WRITE : Int32 = 32 * 1024

///|
const HEADER_SIZE : Int32 = 5

///|
/// A frame from the sidecar.
priv enum Frame {
  /// The child is running, with the pid it was spawned as.
  Hello(version~ : Int32, pid~ : Int32)
  /// Bytes read from the pty master (stdout and stderr merged).
  Output(Bytes)
  /// The child terminated: exit code, or `-signal` when a signal killed it.
  Exit(status~ : Int32)
  /// The sidecar refused a command, or failed at something of its own.
  Error(errno~ : Int32, message~ : String)
}

///|
/// The sidecar sent something this package cannot make sense of.
pub suberror ProtocolError {
  ProtocolError(String)
}

///|
/// Frame encoder and decoder over the sidecar's pipe pair.
///
/// One task reads (the output pump) and one task writes (the command pump), so
/// the connection itself needs no lock. Incoming bytes are accumulated in
/// `buf`, so a frame split across reads is reassembled.
priv struct Connection {
  reader : &@async/io.Reader
  writer : &@async/io.Writer
  mut buf : FixedArray[Byte]
  mut len : Int32
  // Set once a send failed part way: the sidecar is then waiting for the rest
  // of that frame and nothing sent later can be parsed correctly.
  mut broken : Bool
}

///|
fn Connection::new(
  reader : &@async/io.Reader,
  writer : &@async/io.Writer,
) -> Connection {
  {
    reader,
    writer,
    buf: FixedArray::make(4096, b'\x00'),
    len: 0,
    broken: false,
  }
}

///|
/// Make sure at least `needed` bytes are buffered. Returns `false` on a clean
/// EOF before the first byte of a frame, raises on EOF inside one.
async fn Connection::fill(self : Connection, needed : Int32) -> Bool {
  if self.buf.length() < needed {
    let grown = FixedArray::make(needed, b'\x00')
    for i in 0..<self.len {
      grown[i] = self.buf[i]
    }
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
      raise ProtocolError("sidecar closed in the middle of a frame")
    }
    self.len += n
  }
  true
}

///|
/// Drop the first `count` buffered bytes.
fn Connection::consume(self : Connection, count : Int32) -> Unit {
  for i in count..<self.len {
    self.buf[i - count] = self.buf[i]
  }
  self.len -= count
}

///|
/// Next frame from the sidecar, `None` once it has closed its output.
async fn Connection::read_frame(self : Connection) -> Frame? {
  guard self.fill(HEADER_SIZE) else { return None }
  let tag = self.buf[0]
  let len = (self.buf[1].to_int() & 0xFF) |
    ((self.buf[2].to_int() & 0xFF) << 8) |
    ((self.buf[3].to_int() & 0xFF) << 16) |
    ((self.buf[4].to_int() & 0xFF) << 24)
  if len < 0 || len > MAX_PAYLOAD {
    raise ProtocolError("sidecar frame length \{len} out of range")
  }
  guard self.fill(HEADER_SIZE + len) else {
    raise ProtocolError("sidecar closed in the middle of a frame")
  }
  let payload = Bytes::from_array(self.buf[HEADER_SIZE:HEADER_SIZE + len])
  self.consume(HEADER_SIZE + len)
  match tag {
    TAG_HELLO if len == 8 =>
      Some(
        Hello(
          version=u32_at(payload, 0).reinterpret_as_int(),
          pid=u32_at(payload, 4).reinterpret_as_int(),
        ),
      )
    TAG_OUTPUT => Some(Output(payload))
    TAG_EXIT if len == 4 =>
      Some(Exit(status=u32_at(payload, 0).reinterpret_as_int()))
    TAG_ERROR if len >= 4 =>
      Some(
        Error(
          errno=u32_at(payload, 0).reinterpret_as_int(),
          message=@encoding/utf8.decode_lossy(payload[4:]),
        ),
      )
    _ => raise ProtocolError("unexpected sidecar frame 0x\{tag.to_int()}")
  }
}

///|
/// Encode one complete frame.
fn encode_frame(tag : Byte, payload : BytesView) -> Bytes {
  let buf = @buffer.Buffer(size_hint=HEADER_SIZE + payload.length())
  buf.write_byte(tag)
  buf.write_uint_le(payload.length().reinterpret_as_uint())
  buf.write_bytes(payload)
  buf.to_bytes()
}

///|
/// Send one encoded frame. A frame once started is not cut short by
/// cancellation: the sidecar parses a contiguous stream.
async fn Connection::send_bytes(self : Connection, frame : Bytes) -> Unit {
  guard !self.broken else {
    raise ProtocolError("sidecar connection broken by an earlier failed send")
  }
  @async.protect_from_cancel(() => {
    errdefer {
      self.broken = true
    }
    self.writer.write(frame)
  })
}

///|
async fn Connection::send(
  self : Connection,
  tag : Byte,
  payload : BytesView,
) -> Unit {
  self.send_bytes(encode_frame(tag, payload))
}

///|
/// Little-endian `u32` at `offset`.
fn u32_at(bytes : BytesView, offset : Int32) -> UInt32 {
  (bytes[offset].to_int() & 0xFF).reinterpret_as_uint() |
  ((bytes[offset + 1].to_int() & 0xFF).reinterpret_as_uint() << 8) |
  ((bytes[offset + 2].to_int() & 0xFF).reinterpret_as_uint() << 16) |
  ((bytes[offset + 3].to_int() & 0xFF).reinterpret_as_uint() << 24)
}
