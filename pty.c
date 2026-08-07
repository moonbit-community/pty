/*
 * pty.c — Cross-platform PTY implementation for MoonBit FFI.
 *
 * Platform-specific code is included from pty_unix.c and pty_win32.c so
 * clangd can parse those files directly while the build still uses one
 * translation unit.
 *
 * All exported functions use MOONBIT_FFI_EXPORT. The PTY handle is plain
 * POD state stored in a GC-managed Bytes allocation (value-as-Bytes
 * pattern) — no finalizer; resource lifetime is explicit via Pty::close.
 */

#include <moonbit.h>
#include "pty_internal.h"

MOONBIT_FFI_EXPORT
MoonBitPty *
moonbit_pty_new(void) {
  return (MoonBitPty *)moonbit_make_bytes(sizeof(MoonBitPty), 0);
}

#include "pty_win32.c"
#include "pty_unix.c"
