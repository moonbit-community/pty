// pty sidecar: opens a pseudo-terminal, spawns a child on it, and relays
// everything over its own stdio pipes on behalf of the `moonbit-community/pty`
// program that started it. The protocol is described in README.md next to this
// file; the MoonBit side is `internal/sidecar`.
//
// Every target (native and wasm) reaches the pty through this process, because
// everything it needs from the MoonBit side is `@async/process` and
// `@async/io`, both of which work on wasm under moonrun.
//
// Channels:
//   stdin   commands from the parent, framed (`tag:u8 len:u32le payload`)
//   stdout  the terminal's output, raw bytes; EOF once the terminal is done
//   stderr  events to the parent, framed like the commands
//
// The first part is shared. Then comes the Unix half (openpty + fork, a
// single-threaded poll loop, SIGCHLD through a self-pipe) and the Windows half
// (ConPTY, one thread per blocking handle).
#if !defined(_WIN32)
#ifndef _GNU_SOURCE
// `grantpt`, `unlockpt` and `ptsname_r` are only declared by glibc's
// <stdlib.h> under _GNU_SOURCE, which has to come before any system header.
#define _GNU_SOURCE
#endif
#endif

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <wchar.h>
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/ttycom.h>
#endif
#endif

#define PROTOCOL_VERSION 1u

enum {
  // parent -> sidecar
  CMD_SPAWN = 0x01,
  CMD_WRITE = 0x02,
  CMD_RESIZE = 0x03,
  CMD_HANGUP = 0x04,
  CMD_KILL = 0x05,
  // sidecar -> parent
  EV_SPAWNED = 0x80,
  EV_SPAWN_FAILED = 0x81,
  EV_WROTE = 0x82,
  EV_WRITE_FAILED = 0x83,
  EV_RESIZED = 0x84,
  EV_EXIT = 0x85,
  EV_FAILED = 0x86,
};

// Largest command payload accepted. SPAWN carries the whole environment, so
// this is generous; anything beyond it is a corrupt stream.
#define MAX_COMMAND (16u << 20)

// Grace period between hanging up the terminal and killing the child when
// the parent goes away without asking for it. Keep in sync with the MoonBit
// side's cancellation cleanup (pty.mbt) and docs/invariants.md.
#define GRACE_MS 5000

// The error code reported for operations on a terminal that has already been
// hung up. 9 is EBADF on every Unix and the value the library has always
// used on Windows for a closed pseudoconsole.
#define CLOSED_ERROR 9

// ===== shared: growable byte buffers and frame encoding =====

struct buf {
  uint8_t *p;
  size_t len, cap;
};

static void
fatal_oom(void) {
  // Nothing sensible can be reported without memory; the parent sees the
  // event pipe close without an EXIT and reports the sidecar as lost.
  abort();
}

static void
buf_reserve(struct buf *b, size_t extra) {
  if (b->len + extra <= b->cap)
    return;
  size_t cap = b->cap ? b->cap : 4096;
  while (cap < b->len + extra)
    cap *= 2;
  uint8_t *p = realloc(b->p, cap);
  if (!p)
    fatal_oom();
  b->p = p;
  b->cap = cap;
}

static void
buf_append(struct buf *b, const void *p, size_t n) {
  if (!n)
    return;
  buf_reserve(b, n);
  memcpy(b->p + b->len, p, n);
  b->len += n;
}

static void
put_u32(uint8_t *p, uint32_t v) {
  p[0] = v & 0xff;
  p[1] = (v >> 8) & 0xff;
  p[2] = (v >> 16) & 0xff;
  p[3] = (v >> 24) & 0xff;
}

static uint32_t
get_u32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static unsigned
get_u16(const uint8_t *p) {
  return (unsigned)p[0] | ((unsigned)p[1] << 8);
}

// Implemented per platform: queue (Unix) or write (Windows) one event frame.
static void
send_frame(uint8_t tag, const void *payload, uint32_t len);

static void
send_i32(uint8_t tag, int32_t v) {
  uint8_t p[4];
  put_u32(p, (uint32_t)v);
  send_frame(tag, p, sizeof p);
}

static void
send_failed(int32_t code, const char *what) {
  size_t n = strlen(what);
  uint8_t *p = malloc(4 + n);
  if (!p)
    fatal_oom();
  put_u32(p, (uint32_t)code);
  memcpy(p + 4, what, n);
  send_frame(EV_FAILED, p, (uint32_t)(4 + n));
  free(p);
}

// ===== shared: the SPAWN request =====
//
// payload: u32 version, u16 rows, u16 cols, then four string lists, each a
// u32 count followed by that many `u32 len, bytes` strings (UTF-8, no NUL):
//   candidates  executables to try, in order
//   argv        Unix: the child's argv; Windows: one string, the command line
//   env         "KEY=VALUE" entries, the child's whole environment
//   cwd         zero or one string; none keeps the sidecar's directory

struct strlist {
  uint32_t n;
  char **v; // NUL-terminated copies, v[n] == NULL
};

struct spawn_request {
  unsigned rows, cols;
  struct strlist candidates, argv, env, cwd;
};

static int
parse_strlist(const uint8_t **p, const uint8_t *end, struct strlist *out) {
  if (end - *p < 4)
    return -1;
  uint32_t n = get_u32(*p);
  *p += 4;
  if (n > (uint32_t)(end - *p) / 4)
    return -1;
  out->n = n;
  out->v = calloc((size_t)n + 1, sizeof(char *));
  if (!out->v)
    fatal_oom();
  for (uint32_t i = 0; i < n; i++) {
    if (end - *p < 4)
      return -1;
    uint32_t len = get_u32(*p);
    *p += 4;
    if (len > (uint32_t)(end - *p))
      return -1;
    out->v[i] = malloc((size_t)len + 1);
    if (!out->v[i])
      fatal_oom();
    memcpy(out->v[i], *p, len);
    out->v[i][len] = 0;
    *p += len;
  }
  return 0;
}

static int
parse_spawn(const uint8_t *p, size_t len, struct spawn_request *req) {
  const uint8_t *end = p + len;
  memset(req, 0, sizeof *req);
  if (len < 8 || get_u32(p) != PROTOCOL_VERSION)
    return -1;
  req->rows = get_u16(p + 4);
  req->cols = get_u16(p + 6);
  p += 8;
  if (parse_strlist(&p, end, &req->candidates) < 0)
    return -1;
  if (parse_strlist(&p, end, &req->argv) < 0)
    return -1;
  if (parse_strlist(&p, end, &req->env) < 0)
    return -1;
  if (parse_strlist(&p, end, &req->cwd) < 0)
    return -1;
  if (req->cwd.n > 1 || p != end)
    return -1;
  return 0;
}

#if !defined(_WIN32)

// ===== Unix =====

// Drop the first `n` bytes.
static void
buf_consume(struct buf *b, size_t n) {
  memmove(b->p, b->p + n, b->len - n);
  b->len -= n;
}

static struct buf ev_out;   // queued event frames for stderr
static struct buf term_out; // queued terminal output for stdout
static struct buf term_in;  // queued WRITE payloads for the primary
static struct buf cmd_in;   // unparsed command bytes from stdin

static int primary = -1;
static pid_t child = -1;
static int child_reaped = 0;
static int stdin_eof = 0;
static int stdout_open = 1; // fd 1 still open
static int stderr_broken = 0;
static int primary_eof = 0;
static int sigchld_pipe[2] = {-1, -1};
static int64_t kill_deadline = -1; // monotonic ms, -1 when none

// Stop reading the terminal while this much output is queued for the parent:
// the pipe to the parent then pushes back on the child, like the kernel's pty
// queue does.
#define TERM_OUT_HIGH (64 * 1024)

static void
send_frame(uint8_t tag, const void *payload, uint32_t len) {
  if (stderr_broken)
    return;
  uint8_t hdr[5] = {tag};
  put_u32(hdr + 1, len);
  buf_append(&ev_out, hdr, sizeof hdr);
  buf_append(&ev_out, payload, len);
}

static int64_t
now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int
set_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0)
    return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int
set_cloexec(int fd) {
  return fcntl(fd, F_SETFD, FD_CLOEXEC);
}

static void
on_sigchld(int sig) {
  (void)sig;
  int saved = errno;
  char c = 0;
  ssize_t n = write(sigchld_pipe[1], &c, 1);
  (void)n;
  errno = saved;
}

// Same termios as the native library always set: what a program expects from
// a fresh terminal. Programs that want raw mode set it themselves.
static void
default_termios(struct termios *t) {
  memset(t, 0, sizeof *t);
  t->c_iflag = ICRNL | IXON | IXANY | IMAXBEL | BRKINT;
#if defined(IUTF8)
  t->c_iflag |= IUTF8;
#endif
  t->c_oflag = OPOST | ONLCR;
  t->c_cflag = CS8 | CREAD | HUPCL;
  t->c_lflag = ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL;
  for (size_t i = 0; i < NCCS; i++)
    t->c_cc[i] = _POSIX_VDISABLE;
  t->c_cc[VINTR] = 0x03;
  t->c_cc[VQUIT] = 0x1c;
  t->c_cc[VERASE] = 0x7f;
  t->c_cc[VKILL] = 0x15;
  t->c_cc[VEOF] = 0x04;
  t->c_cc[VSTART] = 0x11;
  t->c_cc[VSTOP] = 0x13;
  t->c_cc[VSUSP] = 0x1a;
  t->c_cc[VREPRINT] = 0x12;
  t->c_cc[VWERASE] = 0x17;
  t->c_cc[VLNEXT] = 0x16;
  t->c_cc[VDISCARD] = 0x0f;
#if defined(VDSUSP)
  t->c_cc[VDSUSP] = 0x19;
#endif
#if defined(VSTATUS)
  t->c_cc[VSTATUS] = 0x14;
#endif
  t->c_cc[VMIN] = 1;
  t->c_cc[VTIME] = 0;
  cfsetispeed(t, B38400);
  cfsetospeed(t, B38400);
}

// Move `fd` to 3 or above so the dup2 onto 0..2 in the child cannot clobber
// it. Closes the original on success.
static int
lift_fd(int fd) {
  if (fd >= 3)
    return fd;
  int nfd = fcntl(fd, F_DUPFD_CLOEXEC, 3);
  int er = errno;
  close(fd);
  errno = er;
  return nfd;
}

static int
open_pty(unsigned rows, unsigned cols, int *out_primary, int *out_replica) {
  int er;
  int p = posix_openpt(O_RDWR | O_NOCTTY);
  if (p < 0)
    return -1;
  if ((p = lift_fd(p)) < 0)
    return -1;
  if (set_cloexec(p) < 0 || grantpt(p) != 0 || unlockpt(p) != 0)
    goto fail_p;
  char name[128];
  if (ptsname_r(p, name, sizeof name) != 0)
    goto fail_p;
  int r = open(name, O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (r < 0)
    goto fail_p;
  if ((r = lift_fd(r)) < 0)
    goto fail_p;
  struct termios t;
  default_termios(&t);
  if (tcsetattr(r, TCSAFLUSH, &t) != 0)
    goto fail_r;
  struct winsize ws = {.ws_row = rows, .ws_col = cols};
  if (ioctl(r, TIOCSWINSZ, &ws) != 0)
    goto fail_r;
  *out_primary = p;
  *out_replica = r;
  return 0;
fail_r:
  er = errno;
  close(r);
  errno = er;
fail_p:
  er = errno;
  close(p);
  errno = er;
  return -1;
}

static void __attribute__((noreturn))
child_fail(int efd, int er) {
  int32_t v = er;
  ssize_t n = write(efd, &v, sizeof v);
  (void)n;
  _exit(127);
}

// `execve`, retrying while it fails with ETXTBSY: a file that was just
// written stays busy until the last writer is gone (docs/invariants.md).
static void
execve_ignore_etxtbsy(const char *path, char *const *argv, char *const *envp) {
  struct timespec delay = {0, 50 * 1000 * 1000};
  for (int attempt = 0; attempt < 20; attempt++) {
    execve(path, argv, envp);
    if (errno != ETXTBSY)
      break;
    nanosleep(&delay, NULL);
  }
  execve(path, argv, envp);
}

// Try every candidate; the error reported is the most informative one, the
// same way `execvp` picks it.
static int
execve_candidates(char **path, char *const *argv, char *const *envp) {
  int execve_errno = ENOENT;
  for (int i = 0; path[i]; i++) {
    execve_ignore_etxtbsy(path[i], argv, envp);
    if (errno == EACCES) {
      execve_errno = EACCES;
    } else if (errno != ENOENT && errno != ENOTDIR) {
      execve_errno = errno;
      break;
    }
  }
  return execve_errno;
}

// Fork the child onto the pty. Returns 0 and sets `child` and `primary`, or
// returns the errno that made it fail.
static int
spawn_child(struct spawn_request *req) {
  int replica;
  if (open_pty(req->rows, req->cols, &primary, &replica) < 0)
    return errno;
  int efds[2];
  if (pipe(efds) < 0) {
    int er = errno;
    close(primary);
    close(replica);
    primary = -1;
    return er;
  }
  set_cloexec(efds[0]);
  set_cloexec(efds[1]);
  pid_t pid = fork();
  if (pid == 0) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sigemptyset(&sa.sa_mask);
    sigprocmask(SIG_SETMASK, &sa.sa_mask, NULL);
    sa.sa_handler = SIG_DFL;
    for (int i = 1; i < NSIG; i++)
      sigaction(i, &sa, NULL);
    int efd = efds[1];
    if (efd < 3) {
      efd = fcntl(efd, F_DUPFD_CLOEXEC, 3);
      if (efd < 0)
        _exit(127);
    }
    if (setsid() < 0)
      child_fail(efd, errno);
    if (ioctl(replica, TIOCSCTTY, 0) < 0)
      child_fail(efd, errno);
    if (
      dup2(replica, STDIN_FILENO) < 0 || dup2(replica, STDOUT_FILENO) < 0 ||
      dup2(replica, STDERR_FILENO) < 0
    )
      child_fail(efd, errno);
    if (req->cwd.n == 1 && chdir(req->cwd.v[0]) < 0)
      child_fail(efd, errno);
    close(replica);
    child_fail(
      efd, execve_candidates(req->candidates.v, req->argv.v, req->env.v)
    );
  }
  int fork_errno = errno;
  close(replica);
  close(efds[1]);
  if (pid < 0) {
    close(efds[0]);
    close(primary);
    primary = -1;
    return fork_errno;
  }
  child = pid;
  // Blocks until the child has exec'd (the CLOEXEC write end closes) or
  // reported why it could not.
  int32_t report;
  size_t got = 0;
  while (got < sizeof report) {
    ssize_t n = read(efds[0], (char *)&report + got, sizeof report - got);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      break;
    got += (size_t)n;
  }
  close(efds[0]);
  if (got == 0)
    return 0;
  int status;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
  }
  child = -1;
  child_reaped = 1;
  close(primary);
  primary = -1;
  return got == sizeof report ? report : EIO;
}

static void
reap_child(void) {
  if (child < 0 || child_reaped)
    return;
  int status;
  pid_t r = waitpid(child, &status, WNOHANG);
  if (r != child)
    return;
  child_reaped = 1;
  int32_t code;
  if (WIFEXITED(status)) {
    code = WEXITSTATUS(status);
  } else if (WIFSIGNALED(status)) {
    // The `@async/process.wait_pid` convention.
    code = -WTERMSIG(status);
  } else {
    code = -1;
  }
  send_i32(EV_EXIT, code);
}

static void
close_stdout(void) {
  if (!stdout_open)
    return;
  close(STDOUT_FILENO);
  stdout_open = 0;
  term_out.len = 0;
}

// Close the terminal: the child's session gets SIGHUP and the output stream
// to the parent ends.
static void
hangup(void) {
  if (primary >= 0) {
    close(primary);
    primary = -1;
  }
  term_in.len = 0;
  close_stdout();
}

static void
kill_child(void) {
  if (child > 0 && !child_reaped)
    kill(-child, SIGKILL);
}

static void
handle_command(uint8_t tag, const uint8_t *p, uint32_t len) {
  switch (tag) {
  case CMD_WRITE:
    if (primary < 0) {
      send_i32(EV_WRITE_FAILED, CLOSED_ERROR);
    } else {
      buf_append(&term_in, p, len);
    }
    break;
  case CMD_RESIZE: {
    if (len != 4) {
      send_failed(EINVAL, "malformed RESIZE command");
      break;
    }
    struct winsize ws = {.ws_row = get_u16(p), .ws_col = get_u16(p + 2)};
    int32_t er = 0;
    if (primary < 0) {
      er = CLOSED_ERROR;
    } else if (ioctl(primary, TIOCSWINSZ, &ws) != 0) {
      er = errno;
    }
    send_i32(EV_RESIZED, er);
    break;
  }
  case CMD_HANGUP:
    hangup();
    break;
  case CMD_KILL:
    kill_child();
    break;
  default:
    send_failed(EINVAL, "unknown command");
    break;
  }
}

// Parse and run every complete command in `cmd_in`. Returns -1 on a corrupt
// stream.
static int
drain_commands(void) {
  size_t off = 0;
  int rc = 0;
  while (cmd_in.len - off >= 5) {
    uint8_t tag = cmd_in.p[off];
    uint32_t len = get_u32(cmd_in.p + off + 1);
    if (len > MAX_COMMAND) {
      rc = -1;
      break;
    }
    if (cmd_in.len - off - 5 < len)
      break;
    handle_command(tag, cmd_in.p + off + 5, len);
    off += 5 + (size_t)len;
  }
  buf_consume(&cmd_in, off);
  return rc;
}

// The parent closed the command pipe (or its event pipe): finish the child
// the way the library's cancellation does, then leave.
static void
begin_shutdown(void) {
  if (stdin_eof)
    return;
  stdin_eof = 1;
  if (child > 0 && !child_reaped) {
    hangup();
    kill_deadline = now_ms() + GRACE_MS;
  }
}

// Read one command frame synchronously (before the loop starts). Returns the
// payload length, or -1 at EOF / on error.
static int64_t
read_first_command(uint8_t *tag) {
  for (;;) {
    if (cmd_in.len >= 5) {
      uint32_t len = get_u32(cmd_in.p + 1);
      if (len > MAX_COMMAND)
        return -1;
      if (cmd_in.len - 5 >= len) {
        *tag = cmd_in.p[0];
        return len;
      }
    }
    buf_reserve(&cmd_in, 65536);
    ssize_t n = read(STDIN_FILENO, cmd_in.p + cmd_in.len, 65536);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      return -1;
    cmd_in.len += (size_t)n;
  }
}

static void
flush_events_blocking(void) {
  while (ev_out.len && !stderr_broken) {
    ssize_t n = write(STDERR_FILENO, ev_out.p, ev_out.len);
    if (n < 0 && (errno == EINTR || errno == EAGAIN)) {
      struct pollfd pfd = {STDERR_FILENO, POLLOUT, 0};
      poll(&pfd, 1, -1);
      continue;
    }
    if (n <= 0) {
      stderr_broken = 1;
      break;
    }
    buf_consume(&ev_out, (size_t)n);
  }
}

int
main(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sigemptyset(&sa.sa_mask);
  // The sidecar lives exactly as long as its command pipe: the parent
  // closing it (or dying) is the only shutdown signal. Terminal-generated
  // signals aimed at the parent's process group must not take it down
  // while the parent survives them.
  sa.sa_handler = SIG_IGN;
  sigaction(SIGPIPE, &sa, NULL);
  sigaction(SIGHUP, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGQUIT, &sa, NULL);

  if (pipe(sigchld_pipe) < 0)
    return 1;
  set_cloexec(sigchld_pipe[0]);
  set_cloexec(sigchld_pipe[1]);
  set_nonblocking(sigchld_pipe[0]);
  set_nonblocking(sigchld_pipe[1]);
  sa.sa_handler = on_sigchld;
  sa.sa_flags = SA_NOCLDSTOP | SA_RESTART;
  sigaction(SIGCHLD, &sa, NULL);

  uint8_t tag;
  int64_t len = read_first_command(&tag);
  if (len < 0)
    return 0;
  struct spawn_request req;
  if (tag != CMD_SPAWN || parse_spawn(cmd_in.p + 5, (size_t)len, &req) < 0) {
    send_failed(EINVAL, "expected a SPAWN command of protocol version 1");
    flush_events_blocking();
    return 1;
  }
  buf_consume(&cmd_in, 5 + (size_t)len);
  int er = spawn_child(&req);
  if (er != 0) {
    send_i32(EV_SPAWN_FAILED, er);
    flush_events_blocking();
    return 0;
  }
  send_i32(EV_SPAWNED, (int32_t)child);

  set_nonblocking(primary);
  set_nonblocking(STDOUT_FILENO);
  set_nonblocking(STDERR_FILENO);

  for (;;) {
    reap_child();
    if (child_reaped && kill_deadline >= 0)
      kill_deadline = -1;
    // After the parent hung up its command pipe, only the child's exit is
    // left to report.
    if (stdin_eof && child_reaped) {
      flush_events_blocking();
      return 0;
    }
    if (primary_eof && term_out.len == 0)
      close_stdout();

    // select, not poll: macOS poll() does not support character devices
    // such as the pty primary.
    fd_set rd, wr;
    FD_ZERO(&rd);
    FD_ZERO(&wr);
    int maxfd = sigchld_pipe[0];
    FD_SET(sigchld_pipe[0], &rd);
    if (!stdin_eof)
      FD_SET(STDIN_FILENO, &rd);
    int want_primary_read =
      primary >= 0 && !primary_eof && term_out.len < TERM_OUT_HIGH;
    int want_primary_write = primary >= 0 && term_in.len > 0;
    if (want_primary_read)
      FD_SET(primary, &rd);
    if (want_primary_write)
      FD_SET(primary, &wr);
    if (primary > maxfd && (want_primary_read || want_primary_write))
      maxfd = primary;
    int want_stdout = stdout_open && term_out.len > 0;
    if (want_stdout)
      FD_SET(STDOUT_FILENO, &wr);
    int want_stderr = ev_out.len > 0 && !stderr_broken;
    if (want_stderr)
      FD_SET(STDERR_FILENO, &wr);
    struct timeval tv, *tvp = NULL;
    if (kill_deadline >= 0) {
      int64_t left = kill_deadline - now_ms();
      if (left < 0)
        left = 0;
      tv.tv_sec = (time_t)(left / 1000);
      tv.tv_usec = (suseconds_t)((left % 1000) * 1000);
      tvp = &tv;
    }
    int rc = select(maxfd + 1, &rd, &wr, NULL, tvp);
    if (rc < 0) {
      if (errno == EINTR)
        continue;
      send_failed(errno, "select");
      flush_events_blocking();
      kill_child();
      return 1;
    }
    if (kill_deadline >= 0 && now_ms() >= kill_deadline) {
      kill_child();
      kill_deadline = -1;
    }
    if (FD_ISSET(sigchld_pipe[0], &rd)) {
      char drain[64];
      while (read(sigchld_pipe[0], drain, sizeof drain) > 0) {
      }
    }
    if (!stdin_eof && FD_ISSET(STDIN_FILENO, &rd)) {
      buf_reserve(&cmd_in, 65536);
      ssize_t n = read(STDIN_FILENO, cmd_in.p + cmd_in.len, 65536);
      if (n > 0) {
        cmd_in.len += (size_t)n;
        if (drain_commands() < 0) {
          send_failed(EINVAL, "corrupt command stream");
          begin_shutdown();
        }
      } else if (n == 0 || (errno != EINTR && errno != EAGAIN)) {
        begin_shutdown();
      }
    }
    // `primary` may have been closed by a HANGUP just above.
    if (
      want_primary_write && primary >= 0 && term_in.len &&
      FD_ISSET(primary, &wr)
    ) {
      ssize_t n = write(primary, term_in.p, term_in.len);
      if (n > 0) {
        buf_consume(&term_in, (size_t)n);
        send_i32(EV_WROTE, (int32_t)n);
      } else if (n < 0 && errno != EINTR && errno != EAGAIN) {
        send_i32(EV_WRITE_FAILED, errno);
        term_in.len = 0;
      }
    }
    if (want_primary_read && primary >= 0 && FD_ISSET(primary, &rd)) {
      uint8_t chunk[4096];
      ssize_t n = read(primary, chunk, sizeof chunk);
      if (n > 0) {
        if (stdout_open)
          buf_append(&term_out, chunk, (size_t)n);
      } else if (n == 0 || (errno != EINTR && errno != EAGAIN)) {
        // EIO is how Linux reports that every replica fd is closed; macOS
        // reports EOF. Either way the terminal has nothing more to say.
        primary_eof = 1;
      }
    }
    if (want_stdout && stdout_open && FD_ISSET(STDOUT_FILENO, &wr)) {
      ssize_t n = write(STDOUT_FILENO, term_out.p, term_out.len);
      if (n > 0) {
        buf_consume(&term_out, (size_t)n);
      } else if (n < 0 && errno != EINTR && errno != EAGAIN) {
        // The parent stopped reading. Keep draining the terminal into the
        // void so the child is never stuck on a full queue.
        close_stdout();
      }
    }
    if (want_stderr && FD_ISSET(STDERR_FILENO, &wr)) {
      ssize_t n = write(STDERR_FILENO, ev_out.p, ev_out.len);
      if (n > 0) {
        buf_consume(&ev_out, (size_t)n);
      } else if (n < 0 && errno != EINTR && errno != EAGAIN) {
        stderr_broken = 1;
        ev_out.len = 0;
        begin_shutdown();
      }
    }
  }
}

#else

// ===== Windows =====

static HANDLE h_stdin, h_stdout, h_stderr;
static HANDLE input_writer = INVALID_HANDLE_VALUE;  // to the pseudoconsole
static HANDLE output_reader = INVALID_HANDLE_VALUE; // from the pseudoconsole
static HPCON hpc = NULL;
static HANDLE process = NULL;
static HANDLE job = NULL;
static DWORD child_pid = 0;
static volatile LONG hpc_closed = 0;
static CRITICAL_SECTION ev_lock;  // one event frame at a time on stderr
static CRITICAL_SECTION hpc_lock; // ResizePseudoConsole vs ClosePseudoConsole
static volatile LONG stderr_broken = 0;

// WRITE payloads, handed to the writer thread.
static CRITICAL_SECTION in_lock;
static CONDITION_VARIABLE in_ready;
static struct buf term_in;

static int
write_all(HANDLE h, const void *p, DWORD n) {
  const uint8_t *q = p;
  while (n) {
    DWORD w = 0;
    if (!WriteFile(h, q, n, &w, NULL))
      return -1;
    q += w;
    n -= w;
  }
  return 0;
}

static void
send_frame(uint8_t tag, const void *payload, uint32_t len) {
  uint8_t hdr[5] = {tag};
  put_u32(hdr + 1, len);
  EnterCriticalSection(&ev_lock);
  if (!stderr_broken) {
    if (
      write_all(h_stderr, hdr, sizeof hdr) < 0 ||
      (len && write_all(h_stderr, payload, len) < 0)
    )
      InterlockedExchange(&stderr_broken, 1);
  }
  LeaveCriticalSection(&ev_lock);
}

static WCHAR *
widen(const char *s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
  if (n <= 0)
    return NULL;
  WCHAR *w = malloc((size_t)n * sizeof(WCHAR));
  if (!w)
    fatal_oom();
  MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
  return w;
}

// A copy of `path` made absolute against this process's state (current
// directory, per-drive directories), which is the parent's: the sidecar is
// started without a cwd of its own. Returns NULL on failure.
static WCHAR *
full_path(const WCHAR *path) {
  DWORD n = GetFullPathNameW(path, 0, NULL, NULL);
  if (n == 0)
    return NULL;
  WCHAR *w = malloc((size_t)n * sizeof(WCHAR));
  if (!w)
    fatal_oom();
  DWORD m = GetFullPathNameW(path, n, w, NULL);
  if (m == 0 || m >= n) {
    free(w);
    return NULL;
  }
  return w;
}

static int
file_exists(const WCHAR *path) {
  DWORD attrs = GetFileAttributesW(path);
  return attrs != INVALID_FILE_ATTRIBUTES &&
         !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

static void
close_pseudo_console(void) {
  if (InterlockedExchange(&hpc_closed, 1))
    return;
  EnterCriticalSection(&hpc_lock);
  HPCON h = hpc;
  hpc = NULL;
  LeaveCriticalSection(&hpc_lock);
  // Before Windows 11 24H2 this waits for the pseudoconsole to exit, which
  // needs its output pipe drained: the output thread always keeps reading,
  // even once the parent stopped (docs/invariants.md).
  if (h)
    ClosePseudoConsole(h);
}

static DWORD WINAPI
close_pseudo_console_thread(LPVOID arg) {
  (void)arg;
  close_pseudo_console();
  return 0;
}

static void
close_pseudo_console_async(void) {
  HANDLE t = CreateThread(NULL, 0, close_pseudo_console_thread, NULL, 0, NULL);
  if (t) {
    CloseHandle(t);
  } else {
    close_pseudo_console();
  }
}

static void
kill_child(void) {
  if (job) {
    TerminateJobObject(job, 1);
  } else if (process) {
    TerminateProcess(process, 1);
  }
}

static DWORD WINAPI
writer_thread(LPVOID arg) {
  (void)arg;
  uint8_t *chunk = NULL;
  for (;;) {
    EnterCriticalSection(&in_lock);
    while (term_in.len == 0)
      SleepConditionVariableCS(&in_ready, &in_lock, INFINITE);
    size_t n = term_in.len;
    chunk = realloc(chunk, n);
    if (!chunk)
      fatal_oom();
    memcpy(chunk, term_in.p, n);
    term_in.len = 0;
    LeaveCriticalSection(&in_lock);
    if (write_all(input_writer, chunk, (DWORD)n) < 0) {
      send_i32(EV_WRITE_FAILED, (int32_t)GetLastError());
      free(chunk);
      return 0;
    }
    send_i32(EV_WROTE, (int32_t)n);
  }
}

static DWORD WINAPI
output_thread(LPVOID arg) {
  (void)arg;
  uint8_t chunk[4096];
  int broken = 0;
  for (;;) {
    DWORD n = 0;
    if (!ReadFile(output_reader, chunk, sizeof chunk, &n, NULL) || n == 0)
      break;
    // Once the parent stops reading, keep draining into the void so that
    // ClosePseudoConsole can never block on a full pipe.
    if (!broken && write_all(h_stdout, chunk, n) < 0) {
      broken = 1;
      CloseHandle(h_stdout);
    }
  }
  if (!broken)
    CloseHandle(h_stdout);
  return 0;
}

static DWORD WINAPI
wait_thread(LPVOID arg) {
  (void)arg;
  WaitForSingleObject(process, INFINITE);
  DWORD code = 1;
  GetExitCodeProcess(process, &code);
  send_i32(EV_EXIT, (int32_t)code);
  // The output pipe only reaches EOF once the pseudoconsole is closed.
  close_pseudo_console();
  return 0;
}

static int
start_thread(LPTHREAD_START_ROUTINE fn) {
  HANDLE t = CreateThread(NULL, 0, fn, NULL, 0, NULL);
  if (!t)
    return -1;
  CloseHandle(t);
  return 0;
}

// Build the UTF-16 environment block "K=V\0...\0\0".
static WCHAR *
env_block(struct strlist *env) {
  size_t total = 1;
  WCHAR **wide = calloc((size_t)env->n + 1, sizeof(WCHAR *));
  if (!wide)
    fatal_oom();
  for (uint32_t i = 0; i < env->n; i++) {
    wide[i] = widen(env->v[i]);
    if (!wide[i])
      return NULL;
    total += wcslen(wide[i]) + 1;
  }
  if (env->n == 0)
    total++;
  WCHAR *block = malloc(total * sizeof(WCHAR));
  if (!block)
    fatal_oom();
  WCHAR *p = block;
  for (uint32_t i = 0; i < env->n; i++) {
    size_t n = wcslen(wide[i]) + 1;
    memcpy(p, wide[i], n * sizeof(WCHAR));
    p += n;
    free(wide[i]);
  }
  if (env->n == 0)
    *p++ = 0;
  *p = 0;
  free(wide);
  return block;
}

// Returns 0, or the Win32 error that made it fail.
static DWORD
spawn_child(struct spawn_request *req) {
  WCHAR *app = NULL;
  for (uint32_t i = 0; i < req->candidates.n && !app; i++) {
    WCHAR *w = widen(req->candidates.v[i]);
    WCHAR *full = w ? full_path(w) : NULL;
    free(w);
    if (full && file_exists(full)) {
      app = full;
    } else {
      free(full);
    }
  }
  if (!app)
    return ERROR_FILE_NOT_FOUND;
  if (req->argv.n != 1)
    return ERROR_INVALID_PARAMETER;
  WCHAR *cmd = widen(req->argv.v[0]);
  WCHAR *env = env_block(&req->env);
  WCHAR *cwd = NULL;
  if (req->cwd.n == 1) {
    WCHAR *w = widen(req->cwd.v[0]);
    cwd = w ? full_path(w) : NULL;
    free(w);
  }
  if (!cmd || !env || (req->cwd.n == 1 && !cwd))
    return GetLastError();

  HANDLE input_reader = INVALID_HANDLE_VALUE,
         output_writer = INVALID_HANDLE_VALUE;
  if (!CreatePipe(&input_reader, &input_writer, NULL, 0))
    return GetLastError();
  if (!CreatePipe(&output_reader, &output_writer, NULL, 0))
    return GetLastError();
  COORD size = {(SHORT)req->cols, (SHORT)req->rows};
  HRESULT hr = CreatePseudoConsole(size, input_reader, output_writer, 0, &hpc);
  CloseHandle(input_reader);
  CloseHandle(output_writer);
  if (FAILED(hr))
    return HRESULT_CODE(hr);

  // STARTF_USESTDHANDLES with null handles: without it CreateProcessW
  // duplicates our own (redirected) std handles into the child, and its
  // output bypasses the pseudoconsole (docs/invariants.md).
  STARTUPINFOEXW si;
  memset(&si, 0, sizeof si);
  si.StartupInfo.cb = sizeof si;
  si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  SIZE_T attr_size = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
  si.lpAttributeList = malloc(attr_size);
  if (!si.lpAttributeList)
    fatal_oom();
  if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size))
    return GetLastError();
  if (!UpdateProcThreadAttribute(
        si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc,
        sizeof hpc, NULL, NULL
      ))
    return GetLastError();

  // The job kills the whole tree on KILL, and with the sidecar if it dies.
  job = CreateJobObjectW(NULL, NULL);
  if (job) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
    memset(&info, 0, sizeof info);
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(
          job, JobObjectExtendedLimitInformation, &info, sizeof info
        )) {
      CloseHandle(job);
      job = NULL;
    }
  }

  PROCESS_INFORMATION pi;
  memset(&pi, 0, sizeof pi);
  BOOL ok = CreateProcessW(
    app, cmd, NULL, NULL, FALSE,
    EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT |
      CREATE_SUSPENDED,
    env, cwd, &si.StartupInfo, &pi
  );
  DWORD er = ok ? 0 : GetLastError();
  DeleteProcThreadAttributeList(si.lpAttributeList);
  free(si.lpAttributeList);
  free(app);
  free(cmd);
  free(env);
  free(cwd);
  if (!ok)
    return er;
  if (job && !AssignProcessToJobObject(job, pi.hProcess)) {
    CloseHandle(job);
    job = NULL;
  }
  ResumeThread(pi.hThread);
  CloseHandle(pi.hThread);
  process = pi.hProcess;
  child_pid = pi.dwProcessId;
  return 0;
}

static int
read_exact(uint8_t *p, size_t n) {
  while (n) {
    DWORD got = 0;
    if (
      !ReadFile(h_stdin, p, (DWORD)(n > 65536 ? 65536 : n), &got, NULL) ||
      got == 0
    )
      return -1;
    p += got;
    n -= got;
  }
  return 0;
}

// Read one command; returns its payload (malloc'd) or NULL at EOF.
static uint8_t *
read_command(uint8_t *tag, uint32_t *len) {
  uint8_t hdr[5];
  if (read_exact(hdr, sizeof hdr) < 0)
    return NULL;
  *tag = hdr[0];
  *len = get_u32(hdr + 1);
  if (*len > MAX_COMMAND)
    return NULL;
  uint8_t *p = malloc(*len ? *len : 1);
  if (!p)
    fatal_oom();
  if (read_exact(p, *len) < 0) {
    free(p);
    return NULL;
  }
  return p;
}

// The parent closed the command pipe: finish the child the way the library's
// cancellation does, then leave.
static void
shutdown_and_exit(void) {
  if (process && WaitForSingleObject(process, 0) == WAIT_TIMEOUT) {
    close_pseudo_console_async();
    if (WaitForSingleObject(process, GRACE_MS) == WAIT_TIMEOUT)
      kill_child();
    WaitForSingleObject(process, GRACE_MS);
  }
  ExitProcess(0);
}

int
main(void) {
  h_stdin = GetStdHandle(STD_INPUT_HANDLE);
  h_stdout = GetStdHandle(STD_OUTPUT_HANDLE);
  h_stderr = GetStdHandle(STD_ERROR_HANDLE);
  InitializeCriticalSection(&ev_lock);
  InitializeCriticalSection(&hpc_lock);
  InitializeCriticalSection(&in_lock);
  InitializeConditionVariable(&in_ready);

  uint8_t tag;
  uint32_t len;
  uint8_t *payload = read_command(&tag, &len);
  if (!payload)
    return 0;
  struct spawn_request req;
  if (tag != CMD_SPAWN || parse_spawn(payload, len, &req) < 0) {
    send_failed(
      ERROR_INVALID_DATA, "expected a SPAWN command of protocol version 1"
    );
    return 1;
  }
  free(payload);
  DWORD er = spawn_child(&req);
  if (er != 0) {
    if (hpc)
      ClosePseudoConsole(hpc);
    send_i32(EV_SPAWN_FAILED, (int32_t)er);
    return 0;
  }
  send_i32(EV_SPAWNED, (int32_t)child_pid);
  if (
    start_thread(output_thread) < 0 || start_thread(writer_thread) < 0 ||
    start_thread(wait_thread) < 0
  ) {
    send_failed((int32_t)GetLastError(), "CreateThread");
    kill_child();
    return 1;
  }

  for (;;) {
    payload = read_command(&tag, &len);
    if (!payload)
      shutdown_and_exit();
    switch (tag) {
    case CMD_WRITE:
      if (hpc_closed) {
        send_i32(EV_WRITE_FAILED, CLOSED_ERROR);
        break;
      }
      EnterCriticalSection(&in_lock);
      buf_append(&term_in, payload, len);
      LeaveCriticalSection(&in_lock);
      WakeConditionVariable(&in_ready);
      break;
    case CMD_RESIZE: {
      if (len != 4) {
        send_failed(ERROR_INVALID_DATA, "malformed RESIZE command");
        break;
      }
      COORD size = {(SHORT)get_u16(payload + 2), (SHORT)get_u16(payload)};
      int32_t code = 0;
      EnterCriticalSection(&hpc_lock);
      if (!hpc) {
        code = CLOSED_ERROR;
      } else {
        HRESULT hr = ResizePseudoConsole(hpc, size);
        if (FAILED(hr))
          code = HRESULT_CODE(hr);
      }
      LeaveCriticalSection(&hpc_lock);
      send_i32(EV_RESIZED, code);
      break;
    }
    case CMD_HANGUP:
      close_pseudo_console_async();
      break;
    case CMD_KILL:
      kill_child();
      break;
    default:
      send_failed(ERROR_INVALID_DATA, "unknown command");
      break;
    }
    free(payload);
  }
}

#endif
