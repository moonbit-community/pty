// pty sidecar: owns one pseudo-terminal and the child process attached to it
// on behalf of a MoonBit program running on the wasm target, and relays both
// over its stdio pipes. One sidecar process serves exactly one pty.
//
// The MoonBit side is the `moonbit-community/pty/wasm` package. Frames are
// `tag:u8 len:u32le payload`:
//
//   parent -> sidecar  0x01 SPAWN   u32 rows, u32 cols,
//                                   u32 npath, npath x (u32 len, bytes),
//                                   u32 argc,  argc  x (u32 len, bytes),
//                                   u32 envc,  envc  x (u32 len, bytes),
//                                   u32 cwdlen, bytes (0 = inherit)
//                      0x02 WRITE   bytes for the pty master
//                      0x03 RESIZE  u32 rows, u32 cols
//                      0x04 KILL    optional u32 signal (default SIGKILL)
//
//   sidecar -> parent  0x80 HELLO   u32 protocol version, u32 pid
//                      0x81 OUTPUT  bytes read from the pty master
//                      0x82 EXIT    u32 status (exit code, or -signal)
//                      0x83 ERROR   u32 errno, UTF-8 message
//
// Everything except SPAWN is optional for a session that ends early; SPAWN
// must be the first frame. EOF on the command pipe, or a signal, hangs up the
// terminal, gives the child the same 5 s grace period the native backend
// gives, kills its process group, and reports the exit status.
//
// Unlike the tty sidecar this program never touches the caller's terminal: it
// owns a fresh pty pair, so there is no raw mode, no termios save/restore and
// no keyboard decoding here.
//
// Build standalone with any C compiler:
//
//   cc -O2 -Wall -o sidecar/sidecar sidecar/sidecar.c

#if defined(_WIN32)

#include <stdio.h>

int main(void) {
  /* Windows keeps using the native ConPTY backend; the sidecar exists for
   * wasm programs, which moonrun runs on a unix host. */
  fprintf(stderr, "pty sidecar: not supported on Windows\n");
  return 1;
}

#else

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/ttycom.h>
#endif

enum {
  TAG_SPAWN = 0x01,
  TAG_WRITE = 0x02,
  TAG_RESIZE = 0x03,
  TAG_KILL = 0x04,
  TAG_HELLO = 0x80,
  TAG_OUTPUT = 0x81,
  TAG_EXIT = 0x82,
  TAG_ERROR = 0x83,
};

#define PROTOCOL_VERSION 1u
/* Largest command frame we accept, matching the buffer below. */
#define MAX_COMMAND (1u << 20)
/* Stop reading the master while this much output waits for the parent. */
#define OUT_HIGH_WATER (1u << 20)
/* Same grace period as the native backend, see docs/invariants.md. */
#define GRACE_PERIOD_MS 5000
/* Refuse to buffer more input for a child that never reads it. */
#define IN_HIGH_WATER (1u << 20)

/* ===== output queue ===== */

// Frames waiting for the parent. Above `OUT_HIGH_WATER` the pty is left
// unread, which is the backpressure: the child's own output blocks instead of
// this process growing without bound. Commands are still processed, so a
// parent that stopped reading events can still shut the session down.
static uint8_t *out_buf = NULL;
static size_t out_len = 0, out_cap = 0;
static int events_dead = 0;

static int queue_bytes(const void *p, size_t n) {
  if (events_dead) {
    return 0;
  }
  if (out_len + n > out_cap) {
    size_t cap = out_cap ? out_cap : 65536;
    while (cap < out_len + n) {
      cap *= 2;
    }
    uint8_t *grown = realloc(out_buf, cap);
    if (grown == NULL) {
      return -1;
    }
    out_buf = grown;
    out_cap = cap;
  }
  memcpy(out_buf + out_len, p, n);
  out_len += n;
  return 0;
}

static void put_u32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v & 0xff);
  p[1] = (uint8_t)((v >> 8) & 0xff);
  p[2] = (uint8_t)((v >> 16) & 0xff);
  p[3] = (uint8_t)((v >> 24) & 0xff);
}

static uint32_t rd_u32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 |
         (uint32_t)p[3] << 24;
}

static int send_frame(uint8_t tag, const void *payload, uint32_t len) {
  uint8_t hdr[5];
  hdr[0] = tag;
  put_u32(hdr + 1, len);
  if (queue_bytes(hdr, sizeof hdr) < 0) {
    return -1;
  }
  if (len != 0 && queue_bytes(payload, len) < 0) {
    return -1;
  }
  return 0;
}

/**
 * Report an error to the parent as a single ERROR frame: `u32 errno` followed
 * by the UTF-8 message. It has to be one frame — the parent decodes the
 * payload as a unit, so a message written after the frame desynchronises the
 * stream.
 */
static int send_error(uint32_t err, const char *msg) {
  size_t msg_len = strlen(msg);
  if (msg_len > MAX_COMMAND) {
    msg_len = MAX_COMMAND;
  }
  size_t len = 4 + msg_len;
  uint8_t *payload = malloc(len);
  if (payload == NULL) {
    return -1;
  }
  put_u32(payload, err);
  memcpy(payload + 4, msg, msg_len);
  int rc = send_frame(TAG_ERROR, payload, (uint32_t)len);
  free(payload);
  return rc;
}

static int report_failure(const char *what) {
  char msg[256];
  snprintf(msg, sizeof msg, "%s failed: %s", what, strerror(errno));
  return send_error((uint32_t)errno, msg);
}

// Write as much of the queue as the pipe takes right now; -1 once the parent
// is gone.
static int flush_out(void) {
  while (out_len > 0) {
    ssize_t w = write(1, out_buf, out_len);
    if (w < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        return 0;
      }
      return -1;
    }
    if (w == 0) {
      return 0;
    }
    memmove(out_buf, out_buf + w, out_len - (size_t)w);
    out_len -= (size_t)w;
  }
  return 0;
}

// Last thing before exiting: everything queued must reach the parent. Gives up
// after the grace period, so a parent that stopped reading cannot keep this
// process alive forever — and the parent's teardown waits for this process to
// exit.
static void flush_out_blocking(void) {
  int budget = GRACE_PERIOD_MS;
  while (out_len > 0) {
    ssize_t w = write(1, out_buf, out_len);
    if (w < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        if (budget <= 0) {
          return;
        }
        struct pollfd pfd = {.fd = 1, .events = POLLOUT, .revents = 0};
        if (poll(&pfd, 1, 100) < 0 && errno != EINTR) {
          return;
        }
        budget -= 100;
        continue;
      }
      return;
    }
    if (w == 0) {
      return;
    }
    memmove(out_buf, out_buf + w, out_len - (size_t)w);
    out_len -= (size_t)w;
  }
}

/* ===== pty pair and child process ===== */

static int master = -1;
static int master_open = 0;
static pid_t child_pid = -1;
static int child_reaped = 0;
static int child_status = 0;
static int stop_requested = 0;

static int sig_pipe[2] = {-1, -1};

static void notify_main(void) {
  int saved = errno;
  uint8_t b = 1;
  ssize_t n = write(sig_pipe[1], &b, 1);
  (void)n;
  errno = saved;
}

static void on_sigchld(int sig) {
  (void)sig;
  notify_main();
}

static void on_stop(int sig) {
  (void)sig;
  stop_requested = 1;
  notify_main();
}

static void drain_sig_pipe(void) {
  uint8_t scratch[64];
  for (;;) {
    ssize_t n = read(sig_pipe[0], scratch, sizeof scratch);
    if (n > 0) {
      continue;
    }
    if (n < 0 && errno == EINTR) {
      continue;
    }
    return;
  }
}

/**
 * Configure the replica the way a program expects a real terminal to behave:
 * canonical input, echo, and the usual control characters. Identical to the
 * native backend's `moonbit_pty_unix_set_termios`; programs that want raw mode
 * (vim, fzf, ...) call `tcsetattr` themselves.
 */
static void set_termios_defaults(struct termios *t) {
  memset(t, 0, sizeof *t);
  t->c_iflag = ICRNL | IXON | IXANY | IMAXBEL | BRKINT;
#if defined(IUTF8)
  t->c_iflag |= IUTF8;
#endif
  t->c_oflag = OPOST | ONLCR;
  t->c_cflag = CS8 | CREAD | HUPCL;
  t->c_lflag = ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL;

  for (size_t i = 0; i < NCCS; i++) {
    t->c_cc[i] = _POSIX_VDISABLE;
  }
  t->c_cc[VINTR] = 0x03;    /* ^C */
  t->c_cc[VQUIT] = 0x1c;    /* ^\ */
  t->c_cc[VERASE] = 0x7f;   /* DEL */
  t->c_cc[VKILL] = 0x15;    /* ^U */
  t->c_cc[VEOF] = 0x04;     /* ^D */
  t->c_cc[VSTART] = 0x11;   /* ^Q */
  t->c_cc[VSTOP] = 0x13;    /* ^S */
  t->c_cc[VSUSP] = 0x1a;    /* ^Z */
  t->c_cc[VREPRINT] = 0x12; /* ^R */
  t->c_cc[VWERASE] = 0x17;  /* ^W */
  t->c_cc[VLNEXT] = 0x16;   /* ^V */
  t->c_cc[VDISCARD] = 0x0f; /* ^O */
#if defined(VDSUSP)
  t->c_cc[VDSUSP] = 0x19; /* ^Y */
#endif
#if defined(VSTATUS)
  t->c_cc[VSTATUS] = 0x14; /* ^T */
#endif
  t->c_cc[VMIN] = 1;
  t->c_cc[VTIME] = 0;

  cfsetispeed(t, B38400);
  cfsetospeed(t, B38400);
}

static int open_pt(const char *path, int oflags) {
  int fd = open(path, oflags);
  if (fd < 0) {
    return -1;
  }
  if (fd >= 3) {
    return fd;
  }
  int nfd = fcntl(fd, F_DUPFD_CLOEXEC, 3);
  int er = errno;
  close(fd);
  errno = er;
  return nfd;
}

static int open_pty(uint32_t rows, uint32_t cols) {
  int saved_errno;
  int primary =
      open_pt("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC | O_NONBLOCK);
  if (primary < 0) {
    return -1;
  }
  if (grantpt(primary) != 0) {
    saved_errno = errno;
    goto fail;
  }
  if (unlockpt(primary) != 0) {
    saved_errno = errno;
    goto fail;
  }
  char name[128];
  if (ptsname_r(primary, name, sizeof name) != 0) {
    saved_errno = errno;
    goto fail;
  }
  int replica = open_pt(name, O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (replica < 0) {
    saved_errno = errno;
    goto fail;
  }
  struct termios t;
  set_termios_defaults(&t);
  if (tcsetattr(replica, TCSAFLUSH, &t) != 0) {
    saved_errno = errno;
    close(replica);
    goto fail;
  }
  struct winsize ws = {(unsigned short)rows, (unsigned short)cols, 0, 0};
  if (ioctl(replica, TIOCSWINSZ, &ws) != 0) {
    saved_errno = errno;
    close(replica);
    goto fail;
  }
  master = primary;
  master_open = 1;
  return replica;

fail:
  close(primary);
  errno = saved_errno;
  return -1;
}

static void write_error_exit(int efd, int er) {
  ssize_t n = write(efd, &er, sizeof er);
  (void)n;
  _exit(127);
}

/** `execve`, retrying while the failure is ETXTBSY (see pty.c). */
static void execve_ignore_etxtbsy(
    const char *path,
    char *const *argv,
    char *const *envp) {
  struct timespec delay = {0, 50 * 1000 * 1000}; /* 50ms */
  for (int attempt = 0; attempt < 20; attempt++) {
    execve(path, argv, envp);
    if (errno != ETXTBSY) {
      break;
    }
    nanosleep(&delay, NULL);
  }
  execve(path, argv, envp);
}

static void execve_candidates(
    char **path,
    char *const *argv,
    char *const *envp) {
  int execve_errno = ENOENT;
  for (int i = 0; path[i]; i++) {
    execve_ignore_etxtbsy(path[i], argv, envp);
    if (errno == EACCES) {
      execve_errno = EACCES;
      continue;
    } else if (errno == ENOENT || errno == ENOTDIR) {
      continue;
    } else {
      execve_errno = errno;
      break;
    }
  }
  errno = execve_errno;
}

struct request {
  uint32_t rows;
  uint32_t cols;
  char **path;
  uint32_t path_n;
  char **argv;
  uint32_t argv_n;
  char **envp;
  uint32_t envp_n;
  char *cwd; /* NULL: inherit */
};

static pid_t spawn_child(int replica, const struct request *req) {
  int efd[2];
  if (pipe(efd) < 0) {
    return -1;
  }
  if (fcntl(efd[0], F_SETFD, FD_CLOEXEC) < 0 ||
      fcntl(efd[1], F_SETFD, FD_CLOEXEC) < 0) {
    int er = errno;
    close(efd[0]);
    close(efd[1]);
    errno = er;
    return -1;
  }
  pid_t pid = fork();
  if (pid < 0) {
    int er = errno;
    close(efd[0]);
    close(efd[1]);
    errno = er;
    return -1;
  }
  if (pid == 0) {
    /* Only async-signal-safe work from here on. */
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sigemptyset(&sa.sa_mask);
    sigprocmask(SIG_SETMASK, &sa.sa_mask, NULL);
    sa.sa_handler = SIG_DFL;
    sa.sa_flags = 0;
    for (int i = 1; i < NSIG; i++) {
      sigaction(i, &sa, NULL);
    }

    int err_fd = efd[1];
    if (err_fd < 3) {
      int n = fcntl(err_fd, F_DUPFD_CLOEXEC, 3);
      if (n < 0) {
        _exit(127);
      }
      err_fd = n;
    }
    int rep = replica;
    if (rep < 3) {
      int n = fcntl(rep, F_DUPFD, 3);
      if (n < 0) {
        write_error_exit(err_fd, errno);
      }
      rep = n;
    }
    if (setsid() < 0) {
      write_error_exit(err_fd, errno);
    }
    if (ioctl(rep, TIOCSCTTY, 0) < 0) {
      write_error_exit(err_fd, errno);
    }
    if (dup2(rep, STDIN_FILENO) < 0 || dup2(rep, STDOUT_FILENO) < 0 ||
        dup2(rep, STDERR_FILENO) < 0) {
      write_error_exit(err_fd, errno);
    }
    if (req->cwd != NULL && chdir(req->cwd) < 0) {
      write_error_exit(err_fd, errno);
    }
    if (rep > 2) {
      close(rep);
    }
    execve_candidates(req->path, req->argv, req->envp);
    write_error_exit(err_fd, errno);
  }

  int report = 0;
  close(efd[1]);
  size_t got = 0;
  while (got < sizeof report) {
    ssize_t n = read(efd[0], (uint8_t *)&report + got, sizeof report - got);
    if (n > 0) {
      got += (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR) {
      continue;
    }
    break;
  }
  close(efd[0]);
  if (got == sizeof report) {
    /* Pre-exec failure: the child is gone (it called `_exit`). */
    int st;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {
      ;
    }
    errno = report;
    return -1;
  }
  return pid;
}

/* ===== child status and shutdown ===== */

static void record_status(int st) {
  child_reaped = 1;
  if (WIFEXITED(st)) {
    child_status = WEXITSTATUS(st);
  } else if (WIFSIGNALED(st)) {
    child_status = -WTERMSIG(st);
  } else {
    child_status = -1;
  }
}

static void reap_child(int block) {
  if (child_reaped || child_pid < 0) {
    return;
  }
  int st = 0;
  pid_t r;
  do {
    r = waitpid(child_pid, &st, block ? 0 : WNOHANG);
  } while (r < 0 && errno == EINTR);
  if (r == child_pid) {
    record_status(st);
  }
}

/** Read whatever the master still holds, then stop. */
static void drain_master(void) {
  if (!master_open) {
    return;
  }
  uint8_t buf[4096];
  for (;;) {
    ssize_t k = read(master, buf, sizeof buf);
    if (k > 0) {
      if (send_frame(TAG_OUTPUT, buf, (uint32_t)k) < 0) {
        events_dead = 1;
      }
      continue;
    }
    if (k == 0) {
      master_open = 0;
      return;
    }
    if (errno == EINTR) {
      continue;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      return;
    }
    master_open = 0; /* EIO: the replica side is gone */
    return;
  }
}

/**
 * Hang up the terminal, give the child the native backend's 5 s grace period,
 * then kill its process group. `child_status` holds the result afterwards.
 */
static void shutdown_child(void) {
  if (child_pid < 0) {
    return;
  }
  if (master_open) {
    close(master);
    master_open = 0;
  }
  int waited = 0;
  while (!child_reaped && waited < GRACE_PERIOD_MS) {
    struct pollfd pfd = {.fd = sig_pipe[0], .events = POLLIN, .revents = 0};
    int n = poll(&pfd, 1, 100);
    if (n > 0) {
      drain_sig_pipe();
    }
    reap_child(0);
    waited += 100;
  }
  if (!child_reaped) {
    kill(-child_pid, SIGKILL);
    reap_child(1);
  }
}

/* ===== input queue ===== */

// Bytes the parent wrote that the pty has not accepted yet. They are queued
// rather than written inline, so a child that stops reading its input never
// blocks command processing or the output relay; `IN_HIGH_WATER` bounds the
// memory instead of letting the queue grow without limit.
static uint8_t *in_buf = NULL;
static size_t in_len = 0, in_cap = 0;

static int queue_input(const uint8_t *p, size_t n) {
  if (in_len + n > IN_HIGH_WATER) {
    return -1;
  }
  if (in_len + n > in_cap) {
    size_t cap = in_cap ? in_cap : 65536;
    while (cap < in_len + n) {
      cap *= 2;
    }
    uint8_t *grown = realloc(in_buf, cap);
    if (grown == NULL) {
      return -1;
    }
    in_buf = grown;
    in_cap = cap;
  }
  memcpy(in_buf + in_len, p, n);
  in_len += n;
  return 0;
}

// Write as much queued input as the pty takes right now; -1 once the terminal
// is gone for a reason other than the child having closed its side.
static int flush_input(void) {
  while (in_len > 0) {
    if (!master_open) {
      in_len = 0;
      return 0;
    }
    ssize_t w = write(master, in_buf, in_len);
    if (w > 0) {
      memmove(in_buf, in_buf + w, in_len - (size_t)w);
      in_len -= (size_t)w;
      continue;
    }
    if (w < 0 && errno == EINTR) {
      continue;
    }
    if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      return 0;
    }
    return -1;
  }
  return 0;
}

/* ===== commands ===== */

static uint8_t cmd_buf[1 << 16];
static size_t cmd_len = 0;

// Apply every complete command in `cmd_buf`. Returns -1 when the sidecar must
// stop (a protocol error, or the parent can no longer be reached).
static int handle_commands(void) {
  size_t off = 0;
  while (cmd_len - off >= 5) {
    uint8_t tag = cmd_buf[off];
    uint32_t len = rd_u32(cmd_buf + off + 1);
    if (len > sizeof cmd_buf - 5) {
      send_error(0, "command frame too large");
      return -1;
    }
    if (cmd_len - off - 5 < len) {
      break;
    }
    const uint8_t *payload = cmd_buf + off + 5;
    switch (tag) {
      case TAG_WRITE:
        if (len != 0 && queue_input(payload, len) < 0) {
          /* Not fatal: the parent can retry once the child drains its input. */
          send_error(ENOBUFS, "pty input queue full");
        }
        break;
      case TAG_RESIZE: {
        if (len != 8) {
          send_error(0, "malformed RESIZE command");
          return -1;
        }
        if (master_open) {
          struct winsize ws = {(unsigned short)rd_u32(payload),
                               (unsigned short)rd_u32(payload + 4), 0, 0};
          if (ioctl(master, TIOCSWINSZ, &ws) != 0) {
            int er = errno;
            close(master);
            master_open = 0;
            send_error((uint32_t)er, "resize failed");
            return -1;
          }
        }
        break;
      }
      // KILL is part of the protocol, but no client sends it yet: the wasm
      // side closes the command pipe and lets the hangup path below run the
      // grace period and the group kill, like the native backends. The tag
      // stays defined so a session that sends it behaves sanely.
      case TAG_KILL: {
        if (child_pid > 0 && !child_reaped) {
          int sig = SIGKILL;
          if (len == 4) {
            sig = (int)rd_u32(payload);
          } else if (len != 0) {
            send_error(0, "malformed KILL command");
            return -1;
          }
          kill(-child_pid, sig);
        }
        break;
      }
      default:
        send_error(0, "unknown command");
        return -1;
    }
    off += 5 + len;
  }
  memmove(cmd_buf, cmd_buf + off, cmd_len - off);
  cmd_len -= off;
  return 0;
}

/* ===== SPAWN request ===== */

static int read_exact(int fd, void *buf, size_t n) {
  uint8_t *p = buf;
  while (n > 0) {
    ssize_t k = read(fd, p, n);
    if (k > 0) {
      p += k;
      n -= (size_t)k;
      continue;
    }
    if (k < 0 && errno == EINTR) {
      continue;
    }
    return -1;
  }
  return 0;
}

static char *take_bytes(const uint8_t *buf, size_t len, size_t *off, uint32_t n) {
  if (len - *off < n || n > MAX_COMMAND) {
    return NULL;
  }
  char *s = malloc((size_t)n + 1);
  if (s == NULL) {
    return NULL;
  }
  memcpy(s, buf + *off, n);
  s[n] = '\0';
  *off += n;
  return s;
}

static int take_strings(
    const uint8_t *buf,
    size_t len,
    size_t *off,
    char ***out,
    uint32_t *out_n) {
  if (len - *off < 4) {
    return -1;
  }
  uint32_t n = rd_u32(buf + *off);
  *off += 4;
  if (n > MAX_COMMAND) {
    return -1;
  }
  char **array = calloc((size_t)n + 1, sizeof(char *));
  if (array == NULL) {
    return -1;
  }
  for (uint32_t i = 0; i < n; i++) {
    if (len - *off < 4) {
      goto fail;
    }
    uint32_t slen = rd_u32(buf + *off);
    *off += 4;
    char *s = take_bytes(buf, len, off, slen);
    if (s == NULL) {
      goto fail;
    }
    array[i] = s;
  }
  array[n] = NULL;
  *out = array;
  *out_n = n;
  return 0;
fail:
  for (uint32_t i = 0; i < n; i++) {
    free(array[i]);
  }
  free(array);
  return -1;
}

static int read_spawn_request(struct request *req) {
  uint8_t hdr[5];
  if (read_exact(0, hdr, sizeof hdr) < 0) {
    return -1;
  }
  if (hdr[0] != TAG_SPAWN) {
    send_error(0, "the first command must be SPAWN");
    return -1;
  }
  uint32_t len = rd_u32(hdr + 1);
  if (len > MAX_COMMAND) {
    send_error(0, "SPAWN frame too large");
    return -1;
  }
  uint8_t *payload = malloc(len == 0 ? 1 : len);
  if (payload == NULL) {
    send_error(ENOMEM, "out of memory");
    return -1;
  }
  if (read_exact(0, payload, len) < 0) {
    free(payload);
    return -1;
  }
  memset(req, 0, sizeof *req);
  size_t off = 0;
  if (len < 8) {
    goto malformed;
  }
  req->rows = rd_u32(payload);
  req->cols = rd_u32(payload + 4);
  off = 8;
  if (take_strings(payload, len, &off, &req->path, &req->path_n) < 0 ||
      take_strings(payload, len, &off, &req->argv, &req->argv_n) < 0 ||
      take_strings(payload, len, &off, &req->envp, &req->envp_n) < 0) {
    goto malformed;
  }
  if (len - off < 4) {
    goto malformed;
  }
  uint32_t cwd_len = rd_u32(payload + off);
  off += 4;
  if (cwd_len != 0) {
    req->cwd = take_bytes(payload, len, &off, cwd_len);
    if (req->cwd == NULL) {
      goto malformed;
    }
  }
  free(payload);
  return 0;
malformed:
  free(payload);
  send_error(0, "malformed SPAWN frame");
  return -1;
}

/* ===== main ===== */

static int send_hello(pid_t pid) {
  uint8_t p[8];
  put_u32(p, PROTOCOL_VERSION);
  put_u32(p + 4, (uint32_t)pid);
  return send_frame(TAG_HELLO, p, sizeof p);
}

static int send_exit(void) {
  uint8_t p[4];
  put_u32(p, (uint32_t)child_status);
  return send_frame(TAG_EXIT, p, sizeof p);
}

int main(void) {
  /* stdout is the event pipe: we own the queue and poll for writability. */
  int flags = fcntl(1, F_GETFL);
  if (flags < 0 || fcntl(1, F_SETFL, flags | O_NONBLOCK) < 0) {
    return 1;
  }
  signal(SIGPIPE, SIG_IGN);

  if (pipe(sig_pipe) < 0) {
    return 1;
  }
  for (int i = 0; i < 2; i++) {
    fcntl(sig_pipe[i], F_SETFD, FD_CLOEXEC);
    fcntl(sig_pipe[i], F_SETFL, fcntl(sig_pipe[i], F_GETFL) | O_NONBLOCK);
  }
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_sigchld;
  sigaction(SIGCHLD, &sa, NULL);
  sa.sa_handler = on_stop;
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGHUP, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);

  struct request req;
  if (read_spawn_request(&req) < 0) {
    flush_out_blocking();
    return 1;
  }

  int replica = open_pty(req.rows, req.cols);
  if (replica < 0) {
    if (report_failure("open /dev/ptmx") < 0) {
      flush_out_blocking();
      return 1;
    }
    flush_out_blocking();
    return 1;
  }
  child_pid = spawn_child(replica, &req);
  close(replica);
  if (child_pid < 0) {
    if (report_failure("spawn") < 0) {
      flush_out_blocking();
      return 1;
    }
    flush_out_blocking();
    return 1;
  }
  if (send_hello(child_pid) < 0) {
    shutdown_child();
    return 1;
  }

  for (;;) {
    if (stop_requested) {
      shutdown_child();
      break;
    }
    struct pollfd fds[4];
    nfds_t nfds = 0;
    int i_cmd = -1, i_master = -1, i_sig = -1, i_out = -1;
    fds[nfds].fd = 0;
    fds[nfds].events = POLLIN;
    fds[nfds].revents = 0;
    i_cmd = (int)nfds++;
    if (master_open &&
        ((!events_dead && out_len < OUT_HIGH_WATER) || in_len > 0)) {
      fds[nfds].fd = master;
      fds[nfds].events = 0;
      if (!events_dead && out_len < OUT_HIGH_WATER) {
        fds[nfds].events |= POLLIN;
      }
      if (in_len > 0) {
        fds[nfds].events |= POLLOUT;
      }
      fds[nfds].revents = 0;
      i_master = (int)nfds++;
    }
    fds[nfds].fd = sig_pipe[0];
    fds[nfds].events = POLLIN;
    fds[nfds].revents = 0;
    i_sig = (int)nfds++;
    if (out_len > 0) {
      fds[nfds].fd = 1;
      fds[nfds].events = POLLOUT;
      fds[nfds].revents = 0;
      i_out = (int)nfds++;
    }
    int n = poll(fds, nfds, -1);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      break;
    }
    if (i_out >= 0 && (fds[i_out].revents & (POLLOUT | POLLERR | POLLHUP))) {
      if (flush_out() < 0) {
        /* The parent stopped reading events; keep running its commands until
         * the command pipe closes, then exit. */
        events_dead = 1;
        out_len = 0;
      }
    }
    if (i_sig >= 0 && (fds[i_sig].revents & POLLIN)) {
      drain_sig_pipe();
      reap_child(0);
      if (child_reaped) {
        drain_master();
        break;
      }
    }
    if (i_master >= 0 && (fds[i_master].revents & POLLOUT)) {
      if (flush_input() < 0) {
        master_open = 0;
        in_len = 0;
      }
    }
    if (i_master >= 0 && (fds[i_master].revents & (POLLIN | POLLHUP | POLLERR))) {
      uint8_t buf[4096];
      ssize_t k = read(master, buf, sizeof buf);
      if (k > 0) {
        if (send_frame(TAG_OUTPUT, buf, (uint32_t)k) < 0) {
          events_dead = 1;
        }
      } else if (k == 0) {
        master_open = 0;
      } else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
        master_open = 0; /* EIO: the replica side is gone */
      }
    }
    if (i_cmd >= 0 && (fds[i_cmd].revents & (POLLIN | POLLHUP | POLLERR))) {
      if (cmd_len == sizeof cmd_buf) {
        send_error(0, "command frame too large");
        shutdown_child();
        break;
      }
      ssize_t k = read(0, cmd_buf + cmd_len, sizeof cmd_buf - cmd_len);
      if (k > 0) {
        cmd_len += (size_t)k;
        if (handle_commands() < 0) {
          shutdown_child();
          break;
        }
      } else if (k == 0) {
        /* The parent closed the command pipe: hang up and clean up. */
        shutdown_child();
        break;
      } else if (errno != EINTR) {
        shutdown_child();
        break;
      }
    }
  }

  if (child_pid > 0 && !child_reaped) {
    shutdown_child();
  }
  send_exit();
  flush_out_blocking();
  return 0;
}

#endif /* _WIN32 */
