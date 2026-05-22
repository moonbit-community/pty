/*
 * Unix PTY implementation for pty.c.
 *
 * This file is included by pty.c and intentionally shares its static helpers
 * and MoonBitPty/pty_handle_t definitions.
 */

#include "pty_internal.h"

#ifndef _WIN32

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* openpty() / login_tty() live in different headers depending on platform. */
#if defined(__APPLE__)
#include <crt_externs.h>
#include <mach-o/dyld.h>
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

static moonbit_bytes_t
moonbit_pty_empty_bytes(void) {
  return moonbit_make_bytes(0, 0);
}

static moonbit_bytes_t
moonbit_pty_copy_bytes(const void *data, size_t len) {
  if (!data || len > INT32_MAX) {
    return moonbit_pty_empty_bytes();
  }
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)len, 0);
  if (len > 0) {
    memcpy(out, data, len);
  }
  return out;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moonbit_pty_self_executable(void) {
#if defined(__APPLE__)
  uint32_t size = 0;
  if (_NSGetExecutablePath(NULL, &size) != -1 || size == 0) {
    return moonbit_pty_empty_bytes();
  }
  char *path = (char *)malloc((size_t)size);
  if (!path) {
    return moonbit_pty_empty_bytes();
  }
  if (_NSGetExecutablePath(path, &size) != 0) {
    free(path);
    return moonbit_pty_empty_bytes();
  }
  moonbit_bytes_t out = moonbit_pty_copy_bytes(path, strlen(path));
  free(path);
  return out;
#elif defined(__linux__)
  size_t cap = 256;
  for (;;) {
    char *path = (char *)malloc(cap);
    if (!path) {
      return moonbit_pty_empty_bytes();
    }
    ssize_t n = readlink("/proc/self/exe", path, cap);
    if (n < 0) {
      free(path);
      return moonbit_pty_empty_bytes();
    }
    if ((size_t)n < cap) {
      moonbit_bytes_t out = moonbit_pty_copy_bytes(path, (size_t)n);
      free(path);
      return out;
    }
    free(path);
    cap *= 2;
  }
#else
  return moonbit_pty_empty_bytes();
#endif
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

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moonbit_pty_self_args_flat(void) {
#if defined(__APPLE__)
  int argc = *_NSGetArgc();
  char **argv = *_NSGetArgv();
  if (argc <= 0 || !argv) {
    return moonbit_pty_empty_bytes();
  }
  size_t total = 0;
  for (int i = 0; i < argc; i++) {
    if (!argv[i]) {
      return moonbit_pty_empty_bytes();
    }
    total += strlen(argv[i]) + 1;
  }
  if (total > INT32_MAX) {
    return moonbit_pty_empty_bytes();
  }
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)total, 0);
  size_t pos = 0;
  for (int i = 0; i < argc; i++) {
    size_t len = strlen(argv[i]);
    memcpy(out + pos, argv[i], len);
    pos += len + 1;
  }
  return out;
#elif defined(__linux__)
  int fd = open("/proc/self/cmdline", O_RDONLY);
  if (fd < 0) {
    return moonbit_pty_empty_bytes();
  }
  char *buf = NULL;
  size_t len = 0;
  int err = moonbit_pty_read_argv_buf(fd, &buf, &len);
  close(fd);
  if (err != 0 || !buf) {
    return moonbit_pty_empty_bytes();
  }
  if (len == 0 || buf[len - 1] != '\0') {
    char *new_buf = (char *)realloc(buf, len + 1);
    if (!new_buf) {
      free(buf);
      return moonbit_pty_empty_bytes();
    }
    buf = new_buf;
    buf[len++] = '\0';
  }
  moonbit_bytes_t out = moonbit_pty_copy_bytes(buf, len);
  free(buf);
  return out;
#else
  return moonbit_pty_empty_bytes();
#endif
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

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_set_invalid_argument(void) {
  errno = EINVAL;
  return -1;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_open(MoonBitPty *pty, int32_t cols, int32_t rows) {
  if (!pty) {
    errno = EINVAL;
    return -1;
  }

  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_col = (unsigned short)cols;
  ws.ws_row = (unsigned short)rows;

  int master_fd = -1;
  int slave_fd = -1;
  if (openpty(&master_fd, &slave_fd, NULL, NULL, &ws) < 0) {
    return -1;
  }
  moonbit_pty_set_nonblocking(master_fd);

  pty_handle_t h;
  moonbit_pty_init_handle(&h);
  h.master_fd = master_fd;
  h.slave_fd = slave_fd;
  pty->handle = h;
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_bind_slave_to_fd(MoonBitPty *pty, int32_t target_fd) {
  if (!pty || pty->handle.slave_fd < 0 || target_fd < 0) {
    errno = EINVAL;
    return -1;
  }
  int slave_fd = pty->handle.slave_fd;
  if (dup2(slave_fd, target_fd) < 0) {
    return -1;
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
    errno = EIO;
    return -1;
  }
  int32_t out = 0;
  memcpy(&out, data, sizeof(out));
  if (out == 0) {
    return 0;
  }
  errno = (int)out;
  return -1;
}

/* ---- resize ------------------------------------------------------------- */

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_resize(MoonBitPty *pty, int32_t cols, int32_t rows) {
  if (!pty || pty->handle.master_fd < 0) {
    errno = EINVAL;
    return -1;
  }

  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_col = (unsigned short)cols;
  ws.ws_row = (unsigned short)rows;

  if (ioctl(pty->handle.master_fd, TIOCSWINSZ, &ws) == 0)
    return 0;
  return -1;
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
  pty_handle_t *h = &pty->handle;
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

#endif
