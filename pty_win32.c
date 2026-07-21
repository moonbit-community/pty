/*
 * Windows ConPTY implementation for pty.c.
 *
 * This file is included by pty.c and intentionally shares its static helpers
 * and MoonBitPty/pty_handle_t definitions.
 */

#include "pty_internal.h"

#ifdef _WIN32

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

/* ---- ConPTY function pointer types (dynamically loaded) ----------------- */

typedef struct {
  short X;
  short Y;
} COORD_T;

typedef HRESULT(WINAPI *PFN_CreatePseudoConsole)(
  COORD_T size,
  HANDLE hInput,
  HANDLE hOutput,
  DWORD dwFlags,
  void **phPC
);
typedef HRESULT(WINAPI *PFN_ResizePseudoConsole)(void *hPC, COORD_T size);
typedef void(WINAPI *PFN_ClosePseudoConsole)(void *hPC);

static PFN_CreatePseudoConsole pfnCreatePseudoConsole = NULL;
static PFN_ResizePseudoConsole pfnResizePseudoConsole = NULL;
static PFN_ClosePseudoConsole pfnClosePseudoConsole = NULL;
static int conpty_loaded = 0;

static int
moonbit_pty_ensure_conpty(void) {
  if (conpty_loaded)
    return (pfnCreatePseudoConsole != NULL) ? 0 : -1;
  conpty_loaded = 1;

  HMODULE k32 = GetModuleHandleA("kernel32.dll");
  if (!k32)
    return -1;

  pfnCreatePseudoConsole =
    (PFN_CreatePseudoConsole)GetProcAddress(k32, "CreatePseudoConsole");
  pfnResizePseudoConsole =
    (PFN_ResizePseudoConsole)GetProcAddress(k32, "ResizePseudoConsole");
  pfnClosePseudoConsole =
    (PFN_ClosePseudoConsole)GetProcAddress(k32, "ClosePseudoConsole");

  return (pfnCreatePseudoConsole && pfnResizePseudoConsole &&
          pfnClosePseudoConsole)
           ? 0
           : -1;
}

static DWORD
moonbit_pty_win32_error_from_hresult(HRESULT hr) {
  if (HRESULT_FACILITY(hr) == FACILITY_WIN32) {
    return HRESULT_CODE(hr);
  }
  switch (hr) {
  case E_INVALIDARG:
    return ERROR_INVALID_PARAMETER;
  case E_OUTOFMEMORY:
    return ERROR_NOT_ENOUGH_MEMORY;
  case E_NOTIMPL:
    return ERROR_NOT_SUPPORTED;
  default:
    return ERROR_GEN_FAILURE;
  }
}

/* ---- pipe helper --------------------------------------------------------- */

static int
moonbit_pty_create_pipe(HANDLE *read_end, HANDLE *write_end) {
  if (!CreatePipe(read_end, write_end, NULL, 0)) {
    *read_end = INVALID_HANDLE_VALUE;
    *write_end = INVALID_HANDLE_VALUE;
    return -1;
  }
  return 0;
}

/* ---- spawn -------------------------------------------------------------- */

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_spawn(
  MoonBitPty *pty,
  const uint8_t *command_line_bytes,
  int32_t cols,
  int32_t rows
) {
  int32_t saved_err = 0;
  if (!pty) {
    SetLastError(ERROR_INVALID_PARAMETER);
    return -1;
  }
  if (moonbit_pty_ensure_conpty() < 0) {
    /* ConPTY unavailable — no meaningful GetLastError, use a sentinel. */
    SetLastError(ERROR_NOT_SUPPORTED);
    return -1;
  }

  if (!command_line_bytes) {
    SetLastError(ERROR_INVALID_PARAMETER);
    return -1;
  }
  int32_t command_line_len = (int32_t)Moonbit_array_length(command_line_bytes);
  if (command_line_len <= 0) {
    SetLastError(ERROR_INVALID_PARAMETER);
    return -1;
  }
  /*
   * CreateProcessA takes a mutable LPSTR and may write into it while parsing.
   * Keep MoonBit's GC-managed Bytes untouched by copying only its logical
   * contents into an owned C buffer, then add our own NUL terminator instead
   * of relying on the runtime's internal Bytes padding.
   */
  char *mutable_command_line = (char *)malloc((size_t)command_line_len + 1);
  if (!mutable_command_line) {
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return -1;
  }
  memcpy(mutable_command_line, command_line_bytes, (size_t)command_line_len);
  mutable_command_line[command_line_len] = '\0';

  HANDLE pipe_in_read = INVALID_HANDLE_VALUE;
  HANDLE pipe_in_write = INVALID_HANDLE_VALUE;
  HANDLE pipe_out_read = INVALID_HANDLE_VALUE;
  HANDLE pipe_out_write = INVALID_HANDLE_VALUE;

  /* pipe_in: keyboard → ConPTY stdin. */
  if (moonbit_pty_create_pipe(&pipe_in_read, &pipe_in_write) < 0) {
    saved_err = (int32_t)GetLastError();
    goto fail;
  }

  /* pipe_out: ConPTY stdout → our async reader. */
  if (moonbit_pty_create_pipe(&pipe_out_read, &pipe_out_write) < 0) {
    saved_err = (int32_t)GetLastError();
    goto fail;
  }

  /* Create the pseudo-console. */
  COORD_T size;
  size.X = (short)cols;
  size.Y = (short)rows;

  void *hpc = NULL;
  HRESULT hr =
    pfnCreatePseudoConsole(size, pipe_in_read, pipe_out_write, 0, &hpc);
  if (FAILED(hr) || !hpc) {
    saved_err = (int32_t)moonbit_pty_win32_error_from_hresult(hr);
    goto fail;
  }

  /* Prepare STARTUPINFOEXA with the pseudo-console attribute. */
  SIZE_T attr_size = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
  LPPROC_THREAD_ATTRIBUTE_LIST attr_list =
    (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attr_size);
  if (!attr_list) {
    saved_err = (int32_t)ERROR_NOT_ENOUGH_MEMORY;
    goto fail_close_hpc;
  }
  if (!InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size)) {
    saved_err = (int32_t)GetLastError();
    HeapFree(GetProcessHeap(), 0, attr_list);
    goto fail_close_hpc;
  }

  /* PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016 */
  if (!UpdateProcThreadAttribute(
        attr_list, 0,
        (DWORD_PTR)0x00020016, /* PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE */
        hpc, sizeof(void *), NULL, NULL
      )) {
    saved_err = (int32_t)GetLastError();
    DeleteProcThreadAttributeList(attr_list);
    HeapFree(GetProcessHeap(), 0, attr_list);
    goto fail_close_hpc;
  }

  STARTUPINFOEXA si;
  ZeroMemory(&si, sizeof(si));
  si.StartupInfo.cb = sizeof(STARTUPINFOEXA);
  /*
   * When the parent stdio is redirected, Windows can otherwise copy those
   * pipe handles into the ConPTY child and bypass the pseudoconsole.
   */
  si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  si.lpAttributeList = attr_list;

  PROCESS_INFORMATION pi;
  ZeroMemory(&pi, sizeof(pi));

  BOOL ok = CreateProcessA(
    NULL, mutable_command_line, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT,
    NULL, NULL, &si.StartupInfo, &pi
  );

  DeleteProcThreadAttributeList(attr_list);
  HeapFree(GetProcessHeap(), 0, attr_list);

  /* CreateProcessA has consumed the command line; safe to free now. */
  free(mutable_command_line);
  mutable_command_line = NULL;

  if (!ok) {
    saved_err = (int32_t)GetLastError();
    goto fail_close_hpc;
  }
  CloseHandle(pipe_in_read);
  pipe_in_read = INVALID_HANDLE_VALUE;
  CloseHandle(pipe_out_write);
  pipe_out_write = INVALID_HANDLE_VALUE;

  /* Build the handle. */
  pty_handle_t h;
  moonbit_pty_init_handle(&h);
  h.hpc = hpc;
  h.pipe_in_read = pipe_in_read;
  h.pipe_in_write = pipe_in_write;
  h.pipe_out_read = pipe_out_read;
  h.pipe_out_write = pipe_out_write;
  h.proc_handle = pi.hProcess;
  h.thread_handle = pi.hThread;

  pty->handle = h;
  return 0;

fail_close_hpc:
  pfnClosePseudoConsole(hpc);
fail:
  if (pipe_in_read != INVALID_HANDLE_VALUE)
    CloseHandle(pipe_in_read);
  if (pipe_in_write != INVALID_HANDLE_VALUE)
    CloseHandle(pipe_in_write);
  if (pipe_out_read != INVALID_HANDLE_VALUE)
    CloseHandle(pipe_out_read);
  if (pipe_out_write != INVALID_HANDLE_VALUE)
    CloseHandle(pipe_out_write);
  free(mutable_command_line);
  SetLastError((DWORD)saved_err);
  return -1;
}

MOONBIT_FFI_EXPORT
void
moonbit_pty_kill_pid(int32_t pid) {
  if (pid <= 0) {
    return;
  }
  HANDLE process = OpenProcess(PROCESS_TERMINATE, FALSE, (DWORD)pid);
  if (!process || process == INVALID_HANDLE_VALUE) {
    return;
  }
  TerminateProcess(process, 1);
  CloseHandle(process);
}

/* ---- resize ------------------------------------------------------------- */

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_resize(MoonBitPty *pty, int32_t cols, int32_t rows) {
  if (!pty || !pty->handle.hpc) {
    SetLastError(ERROR_INVALID_PARAMETER);
    return -1;
  }

  COORD_T size;
  size.X = (short)cols;
  size.Y = (short)rows;
  HRESULT hr = pfnResizePseudoConsole(pty->handle.hpc, size);
  if (SUCCEEDED(hr)) {
    return 0;
  }
  SetLastError(moonbit_pty_win32_error_from_hresult(hr));
  return -1;
}

/* ---- read_fd ------------------------------------------------------------ */

MOONBIT_FFI_EXPORT
HANDLE
moonbit_pty_take_read_fd(MoonBitPty *pty) {
  if (
    !pty || !pty->handle.pipe_out_read ||
    pty->handle.pipe_out_read == INVALID_HANDLE_VALUE
  )
    return INVALID_HANDLE_VALUE;
  HANDLE fd = pty->handle.pipe_out_read;
  pty->handle.pipe_out_read = INVALID_HANDLE_VALUE;
  return fd;
}

MOONBIT_FFI_EXPORT
HANDLE
moonbit_pty_take_write_fd(MoonBitPty *pty) {
  if (
    !pty || !pty->handle.pipe_in_write ||
    pty->handle.pipe_in_write == INVALID_HANDLE_VALUE
  )
    return INVALID_HANDLE_VALUE;
  HANDLE fd = pty->handle.pipe_in_write;
  pty->handle.pipe_in_write = INVALID_HANDLE_VALUE;
  return fd;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_child_pid(MoonBitPty *pty) {
  if (!pty || !pty->handle.proc_handle)
    return -1;
  return (int32_t)GetProcessId(pty->handle.proc_handle);
}

/* ---- close -------------------------------------------------------------- */

MOONBIT_FFI_EXPORT
void
moonbit_pty_close(MoonBitPty *pty) {
  if (!pty)
    return;
  pty_handle_t *h = &pty->handle;
  if (h->proc_handle && h->proc_handle != INVALID_HANDLE_VALUE) {
    TerminateProcess(h->proc_handle, 0);
    CloseHandle(h->proc_handle);
    h->proc_handle = NULL;
  }
  if (h->thread_handle && h->thread_handle != INVALID_HANDLE_VALUE) {
    CloseHandle(h->thread_handle);
    h->thread_handle = NULL;
  }
  if (h->hpc) {
    pfnClosePseudoConsole(h->hpc);
    h->hpc = NULL;
  }
  if (h->pipe_in_read && h->pipe_in_read != INVALID_HANDLE_VALUE) {
    CloseHandle(h->pipe_in_read);
    h->pipe_in_read = NULL;
  }
  if (h->pipe_in_write && h->pipe_in_write != INVALID_HANDLE_VALUE) {
    CloseHandle(h->pipe_in_write);
    h->pipe_in_write = NULL;
  }
  if (h->pipe_out_read && h->pipe_out_read != INVALID_HANDLE_VALUE) {
    CloseHandle(h->pipe_out_read);
    h->pipe_out_read = NULL;
  }
  if (h->pipe_out_write && h->pipe_out_write != INVALID_HANDLE_VALUE) {
    CloseHandle(h->pipe_out_write);
    h->pipe_out_write = NULL;
  }
}

#endif
