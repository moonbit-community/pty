/*
 * pty.c — Cross-platform PTY implementation for MoonBit FFI.
 *
 * Platform-specific code is included from pty_unix.c and pty_win32.c so
 * clangd can parse those files directly while the build still uses one
 * translation unit.
 *
 * All exported functions use MOONBIT_FFI_EXPORT and follow the
 * MoonBit external-object pattern (moonbit_make_external_object).
 */

#include <moonbit.h>
#define MOONBIT_PTY_IMPLEMENTATION
#include "pty_internal.h"

static void
moonbit_pty_init_handle(pty_handle_t *h) {
  memset(h, 0, sizeof(*h));
#ifndef _WIN32
  h->master_fd = -1;
  h->control_fd = -1;
  h->slave_fd = -1;
  h->spawned_pid = -1;
#endif
}

MOONBIT_FFI_EXPORT
MoonBitPty *
moonbit_pty_new(void) {
  MoonBitPty *pty = (MoonBitPty *)moonbit_make_external_object(
    moonbit_pty_finalizer, sizeof(MoonBitPty)
  );
  moonbit_pty_init_handle(&pty->handle);
  return pty;
}

/* -------------------------------------------------------------------------- */
/*  Finalizer (invoked by GC)                                                 */
/* -------------------------------------------------------------------------- */

static void
moonbit_pty_finalizer(void *ptr) {
  (void)ptr;
  /* Resource lifetime is explicit, matching moonbitlang/async RawFd/IoHandle.
   * Users must call Pty::close; GC finalization is intentionally not a
   * fallback close because that would make child process lifetime depend on
   * nondeterministic collection. */
}

#include "pty_win32.c"
#include "pty_unix.c"
