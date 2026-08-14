///|
// Append `arg` to a Windows command line, quoting/escaping it so that
// `CommandLineToArgvW` (and the C runtime's argv parser) recovers `arg`
// verbatim. Ported from moonbitlang/async's `write_arg_with_windows_escape`.
// The rules come from
// https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments:
// backslashes are literal unless they precede a `"`, in which case each is
// doubled and the `"` is escaped as `\"`.
#cfg(platform="windows")
fn StringBuilder::write_arg_with_windows_escape(
  builder : StringBuilder,
  arg : StringView,
) -> Unit {
  if arg is "" {
    builder.write("\"\"")
    return
  }
  // Do not add double quotes if it is unnecessary to do so.
  // This helps with simple cases when the program is not using C argv syntax,
  // such as `rundll32.exe`.
  let need_quote = for char in arg {
    if char is (' ' | '\t' | '"') {
      break true
    }
  } nobreak {
    false
  }
  if !need_quote {
    builder.write_stringview(arg)
    return
  }
  let mut segment_start = 0
  let mut index = 0
  let mut trailing_backslash = 0
  fn flush(skip : Int) {
    if index > segment_start {
      builder.write_stringview(arg[segment_start:index - trailing_backslash])
      if trailing_backslash > 0 {
        builder.write_string(String::make(trailing_backslash * 2, '\\'))
      }
    }
    segment_start = index + skip
  }

  builder.write_char('"')
  while index < arg.length() {
    match arg.code_unit_at(index) {
      '"' => {
        flush(1)
        builder <+ "\\\""
      }
      '\\' => trailing_backslash += 1
      _ => trailing_backslash = 0
    }
    index += 1
  }
  flush(0)
  builder.write_char('"')
}

///|
#cfg(platform="windows")
fn test_arg(arg : String) -> String {
  StringBuilder::new()..write_arg_with_windows_escape(arg).to_string()
}

///|
// Cases from
// https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments,
// ported from moonbitlang/async's `write_arg_with_windows_escape` tests.
#cfg(platform="windows")
test "windows command line arg escape" {
  inspect(
    test_arg("a b c"),
    content=(
      #|"a b c"
    ),
  )
  inspect(
    test_arg("ab\"c"),
    content=(
      #|"ab\"c"
    ),
  )
  inspect(test_arg("\\"), content="\\")
  inspect(test_arg("a\\\\\\c"), content="a\\\\\\c")
  inspect(
    test_arg("a\\\"c"),
    content=(
      #|"a\\\"c"
    ),
  )
  inspect(
    test_arg("a\\\\b c"),
    content=(
      #|"a\\b c"
    ),
  )
  inspect(
    test_arg("ab\" c d"),
    content=(
      #|"ab\" c d"
    ),
  )
}

///|
#cfg(platform="windows")
test "windows command line arg escape empty" {
  inspect(
    test_arg(""),
    content=(
      #|""
    ),
  )
}

///|
#cfg(platform="windows")
test "windows command line arg escape leading quote" {
  inspect(
    test_arg("\"abcd"),
    content=(
      #|"\"abcd"
    ),
  )
}
