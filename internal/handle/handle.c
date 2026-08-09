#if defined(_WIN32)
#include <windows.h>

#include <handleapi.h>

#include "moonbit.h"

MOONBIT_FFI_EXPORT
HANDLE
moonbit_pty_internal_handle_win32_get_invalid_handle_value(void) {
  return INVALID_HANDLE_VALUE;
}

MOONBIT_FFI_EXPORT
HANDLE
moonbit_pty_internal_handle_win32_get_null(void) { return NULL; }

#endif
