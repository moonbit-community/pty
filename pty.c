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
#define MOONBIT_PTY_IMPLEMENTATION
#include "pty_internal.h"

static void
moonbit_pty_init(MoonBitPty *pty) {
  memset(pty, 0, sizeof(*pty));
#ifndef _WIN32
  pty->master_fd = -1;
  pty->control_fd = -1;
  pty->slave_fd = -1;
  pty->spawned_pid = -1;
#endif
}

MOONBIT_FFI_EXPORT
MoonBitPty *
moonbit_pty_new(void) {
  MoonBitPty *pty = (MoonBitPty *)moonbit_make_bytes(sizeof(MoonBitPty), 0);
  moonbit_pty_init(pty);
  return pty;
}

#include "pty_win32.c"
#include "pty_unix.c"
