///|
pub extend Pty with @async/io.Writer::{write_once, write, write_reader}

///|
pub extend Pty with @async/io.Reader::{
  read,
  read_some,
  drop,
  read_all,
  read_until,
  read_exactly,
}

///|
#deprecated("internal")
#doc(hidden)
pub extend Pty with @async/io.Reader::{_direct_read, _get_internal_buffer}
