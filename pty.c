/*
 * pty.c — Cross-platform PTY implementation for MoonBit FFI.
 *
 * Platform-specific code is included from pty_unix.c or pty_win32.c so
 * the public MoonBit FFI wrapper remains in one translation unit.
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
  h->slave_fd = -1;
  h->spawned_pid = -1;
#endif
}

/* Allocate a MoonBitPty representing a failed spawn. `handle` stays inert;
 * `err` stores the captured OS error (errno on Unix, GetLastError on
 * Windows) so MoonBit can report it via moonbit_pty_check_spawn. */
static MoonBitPty *
moonbit_pty_make_failure(int32_t err) {
  MoonBitPty *pty = (MoonBitPty *)moonbit_make_external_object(
    moonbit_pty_finalizer, sizeof(MoonBitPty)
  );
  moonbit_pty_init_handle(&pty->handle);
  pty->spawn_errno = err;
  return pty;
}

/* Allocate a MoonBitPty wrapping a successfully-initialized handle. */
static MoonBitPty *
moonbit_pty_make_success(const pty_handle_t *h) {
  MoonBitPty *pty = (MoonBitPty *)moonbit_make_external_object(
    moonbit_pty_finalizer, sizeof(MoonBitPty)
  );
  pty->handle = *h;
  pty->spawn_errno = 0;
  return pty;
}

/*
 * Return the OS error captured while creating the PTY/process. 0 = success.
 *
 * The value is errno on Unix / GetLastError on Windows (same convention
 * as @os_error.get_errno), so MoonBit can wrap it directly in an OSError.
 */
MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_check_spawn(MoonBitPty *pty) {
  if (!pty)
    return 0;
  return pty->spawn_errno;
}

MOONBIT_FFI_EXPORT
MoonBitPty *
moonbit_pty_failure(int32_t err) {
  return moonbit_pty_make_failure(err);
}

/* -------------------------------------------------------------------------- */
/*  Finalizer (invoked by GC)                                                 */
/* -------------------------------------------------------------------------- */

static void
moonbit_pty_finalizer(void *ptr) {
  MoonBitPty *pty = (MoonBitPty *)ptr;
  moonbit_pty_close_impl(&pty->handle);
}

#include "pty_win32.c"
#include "pty_unix.c"
