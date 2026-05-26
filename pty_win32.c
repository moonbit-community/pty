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

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_set_invalid_argument(void) {
  SetLastError(ERROR_INVALID_PARAMETER);
  return -1;
}

/* Quote one argv item using the parsing rules used by the Microsoft C runtime.
 * CreateProcess accepts a single command-line string, so preserving MoonBit's
 * argv array requires escaping spaces, quotes, and backslash-quote runs here.
 */
static size_t
moonbit_pty_windows_quoted_arg_len(const char *arg) {
  size_t len = strlen(arg);
  int needs_quotes = (len == 0 || strpbrk(arg, " \t\"") != NULL);
  if (!needs_quotes) {
    return len;
  }

  size_t out_len = 2; /* surrounding quotes */
  size_t backslashes = 0;
  for (const char *p = arg; *p; p++) {
    if (*p == '\\') {
      backslashes++;
      out_len++;
    } else if (*p == '"') {
      out_len += backslashes + 2; /* double slashes, then escape quote */
      backslashes = 0;
    } else {
      backslashes = 0;
      out_len++;
    }
  }
  return out_len + backslashes; /* double trailing slashes before final quote */
}

static void
moonbit_pty_windows_write_quoted_arg(char **dst, const char *arg) {
  size_t len = strlen(arg);
  int needs_quotes = (len == 0 || strpbrk(arg, " \t\"") != NULL);
  if (!needs_quotes) {
    memcpy(*dst, arg, len);
    *dst += len;
    return;
  }

  *(*dst)++ = '"';
  size_t backslashes = 0;
  for (const char *p = arg; *p; p++) {
    if (*p == '\\') {
      *(*dst)++ = '\\';
      backslashes++;
    } else if (*p == '"') {
      for (size_t i = 0; i < backslashes; i++) {
        *(*dst)++ = '\\';
      }
      *(*dst)++ = '\\';
      *(*dst)++ = '"';
      backslashes = 0;
    } else {
      backslashes = 0;
      *(*dst)++ = *p;
    }
  }
  for (size_t i = 0; i < backslashes; i++) {
    *(*dst)++ = '\\';
  }
  *(*dst)++ = '"';
}

static char *
moonbit_pty_join_argv_windows(char **argv) {
  if (!argv || !argv[0])
    return NULL;
  size_t total = 1; /* trailing NUL */
  for (int i = 0; argv[i]; i++) {
    if (i > 0) {
      total++;
    }
    total += moonbit_pty_windows_quoted_arg_len(argv[i]);
  }
  char *out = (char *)malloc(total);
  if (!out)
    return NULL;
  char *pos = out;
  for (int i = 0; argv[i]; i++) {
    if (i > 0) {
      *pos++ = ' ';
    }
    moonbit_pty_windows_write_quoted_arg(&pos, argv[i]);
  }
  *pos = '\0';
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
