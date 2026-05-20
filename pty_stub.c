/*
 * pty_stub.c — Cross-platform PTY implementation for MoonBit FFI.
 *
 * macOS/Linux: openpty() + MoonBit async process self-helper; the C
 *              constructor performs login_tty() + execvp() after async spawn
 * Windows: ConPTY (dynamically loaded from kernel32.dll)
 *
 * All exported functions use MOONBIT_FFI_EXPORT and follow the
 * MoonBit external-object pattern (moonbit_make_external_object).
 */

#include <moonbit.h>
#include <stdlib.h>
#include <string.h>

/* -------------------------------------------------------------------------- */
/*  Internal handle structure                                                 */
/* -------------------------------------------------------------------------- */

typedef struct pty_handle {
#ifdef _WIN32
  void *hpc;            /* HPCON */
  void *pipe_in_read;   /* stdin  pipe: read  end */
  void *pipe_in_write;  /* stdin  pipe: write end */
  void *pipe_out_read;  /* stdout pipe: read  end */
  void *pipe_out_write; /* stdout pipe: write end */
  void *proc_handle;    /* child PROCESS_INFORMATION.hProcess */
  void *thread_handle;  /* child PROCESS_INFORMATION.hThread  */
#else
  int master_fd;
  int slave_fd;
  int spawned_pid;
#endif
} pty_handle_t;

/*
 * MoonBitPty is the external-object wrapper seen by MoonBit.
 * moonbit_make_external_object allocates (payload_size) bytes after
 * the GC header; our payload is (pty_handle_t, spawn_errno).
 *
 * `spawn_errno` is 0 on success, otherwise the errno / GetLastError
 * captured while creating the PTY or process. On failure, `handle` is
 * initialized to inert fd/HANDLE values so MoonBit can still call
 * moonbit_pty_check_spawn / moonbit_pty_close on it.
 */
typedef struct {
  pty_handle_t handle;
  int32_t spawn_errno;
} MoonBitPty;

/* Forward declaration of the platform close helper. */
static void
moonbit_pty_close_impl(pty_handle_t *h);
static void
moonbit_pty_finalizer(void *ptr);

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
#endif

/* -------------------------------------------------------------------------- */
/*  Finalizer (invoked by GC)                                                 */
/* -------------------------------------------------------------------------- */

static void
moonbit_pty_finalizer(void *ptr) {
  MoonBitPty *pty = (MoonBitPty *)ptr;
  moonbit_pty_close_impl(&pty->handle);
}

/* ========================================================================== */
/*  UNIX IMPLEMENTATION                                                       */
/* ========================================================================== */
#ifndef _WIN32

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* openpty() / login_tty() live in different headers depending on platform. */
#if defined(__APPLE__)
#include <util.h>
#elif defined(__FreeBSD__) || defined(__DragonFly__)
#include <libutil.h>
#else
#include <pty.h>
#endif

#if defined(__APPLE__) || defined(__linux__)
#define MOONBIT_PTY_USE_ASYNC_SPAWN 1
#define MOONBIT_PTY_EXEC_ENV "MOONBIT_PTY_EXEC"
#else
#define MOONBIT_PTY_USE_ASYNC_SPAWN 0
#endif

static void
moonbit_pty_set_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags >= 0) {
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  }
}

/* Blocking write of exactly `len` bytes of `errno` back to the parent.
 * Retries on EINTR and short writes. The return value is intentionally
 * ignored by callers: we're on a fatal path and if the error pipe is
 * broken the parent will see EOF and fall back to its generic failure
 * path. */
static void
moonbit_pty_report_error(int err_fd, int err) {
  int32_t val = (int32_t)err;
  const char *p = (const char *)&val;
  size_t remaining = sizeof(val);
  while (remaining > 0) {
    ssize_t n = write(err_fd, p, remaining);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      return;
    }
    p += n;
    remaining -= (size_t)n;
  }
}

#if MOONBIT_PTY_USE_ASYNC_SPAWN
/* Constructor-side unsetenv so the target program doesn't inherit our
 * helper-mode marker after execvp. */
static void
moonbit_pty_unset_helper_env(void) {
  unsetenv(MOONBIT_PTY_EXEC_ENV);
}

/* Read the flattened argv buffer from argv_fd until EOF. Wire format is
 * the same null-separated buffer the MoonBit side builds:
 *   "arg0\0arg1\0...arg(n-1)\0"
 * Returns 0 on success with *out_buf / *out_len populated, or an errno
 * on failure. Caller owns *out_buf on success. */
static int
moonbit_pty_read_argv_buf(int argv_fd, char **out_buf, size_t *out_len) {
  size_t cap = 256;
  size_t len = 0;
  char *buf = (char *)malloc(cap);
  if (!buf)
    return ENOMEM;
  for (;;) {
    if (len == cap) {
      size_t new_cap = cap * 2;
      char *new_buf = (char *)realloc(buf, new_cap);
      if (!new_buf) {
        free(buf);
        return ENOMEM;
      }
      buf = new_buf;
      cap = new_cap;
    }
    ssize_t n = read(argv_fd, buf + len, cap - len);
    if (n == 0)
      break;
    if (n < 0) {
      if (errno == EINTR)
        continue;
      int saved = errno;
      free(buf);
      return saved;
    }
    len += (size_t)n;
  }
  *out_buf = buf;
  *out_len = len;
  return 0;
}

/* Split the flat argv buffer in-place into a NULL-terminated argv array.
 * The buffer is already a sequence of null-terminated strings, so the
 * argv entries point directly into it. The buffer must stay alive until
 * execvp runs. */
static char **
moonbit_pty_argv_from_buf(char *buf, size_t len) {
  if (len == 0 || buf[len - 1] != '\0')
    return NULL;
  int argc = 0;
  for (size_t i = 0; i < len; i++) {
    if (buf[i] == '\0')
      argc++;
  }
  if (argc == 0)
    return NULL;
  char **argv = (char **)calloc((size_t)argc + 1, sizeof(char *));
  if (!argv)
    return NULL;
  int idx = 0;
  char *p = buf;
  for (size_t i = 0; i < len; i++) {
    if (buf[i] == '\0') {
      argv[idx++] = p;
      p = buf + i + 1;
    }
  }
  argv[argc] = NULL;
  return argv;
}

/* Helper-mode body: read argv from argv_fd, attach the slave tty, execvp
 * the target. Any pre-exec failure writes the errno to err_fd so the
 * parent can surface it; a successful execvp auto-closes err_fd via
 * FD_CLOEXEC, signalling EOF = success to the parent. */
static int
moonbit_pty_exec_from_pipe(int argv_fd, int err_fd, int slave_fd) {
  sigset_t all_signals;
  sigfillset(&all_signals);
  sigprocmask(SIG_UNBLOCK, &all_signals, NULL);
  signal(SIGPIPE, SIG_DFL);

  char *buf = NULL;
  size_t buf_len = 0;
  int err = moonbit_pty_read_argv_buf(argv_fd, &buf, &buf_len);
  close(argv_fd);
  if (err != 0) {
    moonbit_pty_report_error(err_fd, err);
    return 127;
  }

  char **child_argv = moonbit_pty_argv_from_buf(buf, buf_len);
  if (!child_argv) {
    moonbit_pty_report_error(err_fd, EINVAL);
    free(buf);
    return 127;
  }

  moonbit_pty_unset_helper_env();

  if (login_tty(slave_fd) < 0) {
    moonbit_pty_report_error(err_fd, errno);
    return 126;
  }

  /* Ensure a successful execvp closes err_fd — the parent uses that EOF
   * as its "exec succeeded" signal. If execvp fails, the fd stays open
   * and we can still report the errno below. */
  fcntl(err_fd, F_SETFD, FD_CLOEXEC);

  execvp(child_argv[0], child_argv);
  /* execvp only returns on failure. */
  moonbit_pty_report_error(err_fd, errno);
  return 127;
}

__attribute__((constructor)) static void
moonbit_pty_constructor(void) {
  const char *helper_mode = getenv(MOONBIT_PTY_EXEC_ENV);
  if (!helper_mode || strcmp(helper_mode, "stdio") != 0) {
    return;
  }

  int err_fd = dup(STDERR_FILENO);
  if (err_fd < 0) {
    moonbit_pty_report_error(STDERR_FILENO, errno);
    _exit(127);
  }
  _exit(moonbit_pty_exec_from_pipe(STDIN_FILENO, err_fd, STDOUT_FILENO));
}
#endif

/* ---- platform close ----------------------------------------------------- */

static void
moonbit_pty_close_impl(pty_handle_t *h) {
  if (h->master_fd >= 0) {
    close(h->master_fd);
    h->master_fd = -1;
  }
  if (h->slave_fd >= 0) {
    close(h->slave_fd);
    h->slave_fd = -1;
  }
  h->spawned_pid = -1;
}

MOONBIT_FFI_EXPORT
MoonBitPty *
moonbit_pty_open(int32_t cols, int32_t rows) {
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_col = (unsigned short)cols;
  ws.ws_row = (unsigned short)rows;

  int master_fd = -1;
  int slave_fd = -1;
  if (openpty(&master_fd, &slave_fd, NULL, NULL, &ws) < 0) {
    return moonbit_pty_make_failure((int32_t)errno);
  }
  moonbit_pty_set_nonblocking(master_fd);

  pty_handle_t h;
  moonbit_pty_init_handle(&h);
  h.master_fd = master_fd;
  h.slave_fd = slave_fd;
  return moonbit_pty_make_success(&h);
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_bind_slave_to_fd(MoonBitPty *pty, int32_t target_fd) {
  if (!pty || pty->handle.slave_fd < 0 || target_fd < 0) {
    return (int32_t)EINVAL;
  }
  int slave_fd = pty->handle.slave_fd;
  if (dup2(slave_fd, target_fd) < 0) {
    return (int32_t)errno;
  }
  if (slave_fd != target_fd) {
    close(slave_fd);
  }
  pty->handle.slave_fd = -1;
  return 0;
}

MOONBIT_FFI_EXPORT
void
moonbit_pty_set_child_pid(MoonBitPty *pty, int32_t pid) {
  if (!pty) {
    return;
  }
  pty->handle.spawned_pid = (int)pid;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_decode_child_error(const uint8_t *data) {
  if (!data) {
    return 0;
  }
  int32_t len = (int32_t)Moonbit_array_length(data);
  if (len == 0) {
    return 0;
  }
  if (len != (int32_t)sizeof(int32_t)) {
    return (int32_t)EIO;
  }
  int32_t out = 0;
  memcpy(&out, data, sizeof(out));
  return out;
}

/* ---- resize ------------------------------------------------------------- */

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_resize(MoonBitPty *pty, int32_t cols, int32_t rows) {
  if (!pty || pty->handle.master_fd < 0)
    return (int32_t)EINVAL;

  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_col = (unsigned short)cols;
  ws.ws_row = (unsigned short)rows;

  if (ioctl(pty->handle.master_fd, TIOCSWINSZ, &ws) == 0)
    return 0;
  return (int32_t)errno;
}

/* ---- read_fd ------------------------------------------------------------ */

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_take_read_fd(MoonBitPty *pty) {
  if (!pty || pty->handle.master_fd < 0)
    return -1;
  int fd = pty->handle.master_fd;
  pty->handle.master_fd = -1;
  return (int32_t)fd;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_child_pid(MoonBitPty *pty) {
  if (!pty || pty->handle.spawned_pid < 0)
    return -1;
  return (int32_t)pty->handle.spawned_pid;
}

/* ---- close -------------------------------------------------------------- */

MOONBIT_FFI_EXPORT
void
moonbit_pty_close(MoonBitPty *pty) {
  if (!pty)
    return;
  moonbit_pty_close_impl(&pty->handle);
}

/* ========================================================================== */
/*  WINDOWS IMPLEMENTATION (ConPTY)                                           */
/* ========================================================================== */
#else /* _WIN32 */

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

/* ---- overlapped named-pipe helper --------------------------------------- */

static volatile LONG moonbit_pty_pipe_id = 0;

static int
moonbit_pty_create_overlapped_pipe(HANDLE *read_end, HANDLE *write_end) {
  LONG id = InterlockedIncrement(&moonbit_pty_pipe_id);
  char name[128];
  snprintf(
    name, sizeof(name), "\\\\.\\pipe\\moonbit_pty.%lu.%ld",
    (unsigned long)GetCurrentProcessId(), id
  );

  *write_end = CreateNamedPipeA(
    name, PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED,
    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 4096, 4096, 0, NULL
  );
  if (*write_end == INVALID_HANDLE_VALUE)
    return -1;

  *read_end = CreateFileA(
    name, GENERIC_READ, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL
  );
  if (*read_end == INVALID_HANDLE_VALUE) {
    CloseHandle(*write_end);
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
MoonBitPty *
moonbit_pty_spawn_windows(const uint8_t *argv_flat, int32_t cols, int32_t rows) {
  int32_t saved_err = 0;
  if (moonbit_pty_ensure_conpty() < 0) {
    /* ConPTY unavailable — no meaningful GetLastError, use a sentinel. */
    return moonbit_pty_make_failure((int32_t)ERROR_NOT_SUPPORTED);
  }

  char **parsed_argv = moonbit_pty_parse_argv_flat(argv_flat);
  if (!parsed_argv)
    return moonbit_pty_make_failure((int32_t)ERROR_NOT_ENOUGH_MEMORY);
  char *cmd_line = moonbit_pty_join_argv_windows(parsed_argv);
  moonbit_pty_free_argv(parsed_argv);
  if (!cmd_line)
    return moonbit_pty_make_failure((int32_t)ERROR_NOT_ENOUGH_MEMORY);

  HANDLE pipe_in_read = INVALID_HANDLE_VALUE;
  HANDLE pipe_in_write = INVALID_HANDLE_VALUE;
  HANDLE pipe_out_read = INVALID_HANDLE_VALUE;
  HANDLE pipe_out_write = INVALID_HANDLE_VALUE;

  /* pipe_in: keyboard → ConPTY stdin. Use overlapped named pipe so the
   * write end can be registered with IOCP for async writes from MoonBit. */
  if (moonbit_pty_create_overlapped_pipe(&pipe_in_read, &pipe_in_write) < 0) {
    saved_err = (int32_t)GetLastError();
    goto fail;
  }

  /* pipe_out: ConPTY stdout → our async reader. Use overlapped named pipe
   * so the read end can be registered with IOCP for event-driven reads. */
  if (moonbit_pty_create_overlapped_pipe(&pipe_out_read, &pipe_out_write) < 0) {
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
    saved_err = (int32_t)hr;
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

  return moonbit_pty_make_success(&h);

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
  return moonbit_pty_make_failure(saved_err);
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
  if (!pty || !pty->handle.hpc)
    return (int32_t)ERROR_INVALID_PARAMETER;

  COORD_T size;
  size.X = (short)cols;
  size.Y = (short)rows;
  HRESULT hr = pfnResizePseudoConsole(pty->handle.hpc, size);
  return SUCCEEDED(hr) ? 0 : (int32_t)hr;
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

#endif /* _WIN32 */
