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
