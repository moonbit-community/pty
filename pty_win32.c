/*
 * Windows ConPTY implementation for pty.c.
 *
 * This file is included by pty.c and intentionally shares its static helpers
 * and MoonBitPty/pty_handle_t definitions.
 */

#include "pty_internal.h"

#ifdef _WIN32

static char **
moonbit_pty_parse_argv_flat(const uint8_t *argv_flat) {
  if (!argv_flat) {
    return NULL;
  }
  int32_t flat_len = (int32_t)Moonbit_array_length(argv_flat);
  if (flat_len <= 0 || argv_flat[flat_len - 1] != 0) {
    return NULL; /* Empty, or missing trailing null terminator */
  }

  int32_t argc = 0;
  for (int32_t i = 0; i < flat_len; i++) {
    if (argv_flat[i] == 0)
      argc++;
  }
  if (argc == 0) {
    return NULL;
  }

  char **out = (char **)calloc((size_t)argc + 1, sizeof(char *));
  if (!out) {
    return NULL;
  }

  int32_t pos = 0;
  for (int i = 0; i < argc; i++) {
    int32_t end = pos;
    while (argv_flat[end] != 0) {
      end++;
    }
    int32_t len = end - pos;
    char *str = (char *)malloc((size_t)len + 1);
    if (!str) {
      for (int j = 0; j < i; j++)
        free(out[j]);
      free(out);
      return NULL;
    }
    memcpy(str, argv_flat + pos, (size_t)len);
    str[len] = '\0';
    out[i] = str;
    pos = end + 1;
  }
  out[argc] = NULL;
  return out;
}

static void
moonbit_pty_free_argv(char **argv) {
  if (!argv)
    return;
  for (int i = 0; argv[i]; i++) {
    free(argv[i]);
  }
  free(argv);
}

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

/* ---- platform close ----------------------------------------------------- */

static void
moonbit_pty_close_impl(pty_handle_t *h) {
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

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_set_invalid_argument(void) {
  SetLastError(ERROR_INVALID_PARAMETER);
  return -1;
}

/*
 * Join a parsed argv into a single Windows command-line string.
 *
 * TODO(windows): proper CommandLineToArgvW-compatible quoting. For now this
 * does a naive space-join which works for args that don't contain spaces,
 * tabs, quotes, or backslash-quote sequences. The design doc accepts this
 * as a v1 shortcut. When Windows support becomes real, replace with full
 * escaping per
 * https://learn.microsoft.com/en-us/cpp/cpp/main-function-command-line-args#parsing-c-command-line-arguments
 */
static char *
moonbit_pty_join_argv_windows(char **argv) {
  if (!argv || !argv[0])
    return NULL;
  size_t total = 0;
  for (int i = 0; argv[i]; i++) {
    total += strlen(argv[i]) + 1; /* +1 for space or terminator */
  }
  char *out = (char *)malloc(total);
  if (!out)
    return NULL;
  size_t pos = 0;
  for (int i = 0; argv[i]; i++) {
    size_t len = strlen(argv[i]);
    if (i > 0) {
      out[pos++] = ' ';
    }
    memcpy(out + pos, argv[i], len);
    pos += len;
  }
  out[pos] = '\0';
  return out;
}

/* ---- spawn -------------------------------------------------------------- */

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_spawn_windows(
  MoonBitPty *pty,
  const uint8_t *argv_flat,
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

  char **parsed_argv = moonbit_pty_parse_argv_flat(argv_flat);
  if (!parsed_argv) {
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return -1;
  }
  char *cmd_line = moonbit_pty_join_argv_windows(parsed_argv);
  moonbit_pty_free_argv(parsed_argv);
  if (!cmd_line) {
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return -1;
  }

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
    NULL, cmd_line, /* command line (mutable copy OK — Windows makes its own) */
    NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT, NULL, NULL,
    &si.StartupInfo, &pi
  );

  DeleteProcThreadAttributeList(attr_list);
  HeapFree(GetProcessHeap(), 0, attr_list);

  /* CreateProcessA has consumed the command line; safe to free now. */
  free(cmd_line);
  cmd_line = NULL;

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

  moonbit_pty_close_impl(&pty->handle);
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
  free(cmd_line);
  SetLastError((DWORD)saved_err);
  return -1;
}

MOONBIT_FFI_EXPORT
void
moonbit_pty_kill_pid_windows(int32_t pid) {
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
moonbit_pty_take_write_fd_windows(MoonBitPty *pty) {
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
  moonbit_pty_close_impl(&pty->handle);
}

#endif
