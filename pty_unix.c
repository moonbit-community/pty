#if !defined(_WIN32)
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#define __USE_XOPEN_EXTENDED
#define __USE_GNU
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/ttycom.h>
#endif

#include "moonbit.h"

struct moonbit_pty {
  int32_t primary;
  int32_t replica;
};

/**
 * Configure the replica the way a program expects a real terminal to behave:
 * canonical input, echo, and the usual control characters. Programs that want
 * raw mode (vim, fzf, ...) call `tcsetattr` themselves. Raw mode belongs on the
 * caller's own controlling terminal, not here.
 *
 * These are the pty driver defaults; setting them explicitly keeps the behavior
 * identical across platforms instead of inheriting whatever the driver picks.
 */
static inline void
moonbit_pty_set_termios(struct termios *t) {
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
  /* Ignored while ICANON is set, but a program that turns it off should find
   * the usual "block until at least one byte" behavior. */
  t->c_cc[VMIN] = 1;
  t->c_cc[VTIME] = 0;

  cfsetispeed(t, B38400);
  cfsetospeed(t, B38400);
}

#if defined(__APPLE__)

/** We use `__fork` to skip pthread_atfork handlers. */
extern pid_t
__fork(void) __attribute__((weak_import));

static inline pid_t
moonbit_pty__fork(void) {
  if (&__fork == NULL) {
    errno = ENOSYS;
    return -1;
  }
  return __fork();
}

#else

static inline pid_t
moonbit_pty__fork(void) {
  return fork();
}

#endif

static inline int32_t
moonbit_pty__fd_dup_cloexec_3(int32_t fd) {
  assert(fd >= 0);
  if (fd >= 3) {
    return fd;
  }
  int nfd = fcntl(fd, F_DUPFD_CLOEXEC, 3);
  int er = errno;
  close(fd);
  errno = er;
  return nfd;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_open(struct moonbit_pty *pty, int32_t rows, int32_t cols) {
  int er;

  int p = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC | O_NONBLOCK);
  if (p < 0) {
    return -1;
  }
  p = moonbit_pty__fd_dup_cloexec_3(p);
  if (p < 0) {
    er = errno;
    goto fail_to_dup_primary;
  }

  if (grantpt(p) != 0) {
    er = errno;
    goto fail_to_grant_pt;
  }
  if (unlockpt(p) != 0) {
    er = errno;
    goto fail_to_unlock_pt;
  }

  char nm[128];
  if (ptsname_r(p, nm, sizeof(nm)) != 0) {
    er = errno;
    goto fail_to_get_ptsname;
  }

  int r = open(nm, O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (r < 0) {
    er = errno;
    goto fail_to_open_replica;
  }
  r = moonbit_pty__fd_dup_cloexec_3(r);
  if (r < 0) {
    er = errno;
    goto fail_to_dup_replica;
  }

  struct termios t;
  moonbit_pty_set_termios(&t);
  if (tcsetattr(r, TCSAFLUSH, &t) != 0) {
    er = errno;
    goto fail_to_set_termios;
  }

  struct winsize ws = {
    .ws_row = rows,
    .ws_col = cols,
    .ws_xpixel = 0,
    .ws_ypixel = 0,
  };
  if (ioctl(r, TIOCSWINSZ, &ws) != 0) {
    er = errno;
    goto fail_to_set_winsize;
  }
  pty->primary = p;
  pty->replica = r;
  return 0;

fail_to_set_winsize:
fail_to_set_termios:
  close(r);
fail_to_dup_replica:
fail_to_open_replica:
fail_to_get_ptsname:
fail_to_unlock_pt:
fail_to_grant_pt:
fail_to_dup_primary:
  close(p);
  errno = er;
  return -1;
}

#define MOONBIT_PTY__NORETURN __attribute__((noreturn))

static inline void MOONBIT_PTY__NORETURN
moonbit_pty__fork_fail(int32_t efd) {
  int32_t er = errno;
  ssize_t n = write(efd, &er, sizeof(er));
  _exit(127);
}

static inline char **
moonbit_pty__dup_strings(moonbit_bytes_t *bytes_array) {
  int n = Moonbit_array_length(bytes_array);
  char **dest = malloc((n + 1) * sizeof(char *));
  if (!dest) {
    return NULL;
  }
  for (int i = 0; i < n; i++) {
    int len = Moonbit_array_length(bytes_array[i]) + 1;
    dest[i] = malloc(len);
    if (!dest[i]) {
      for (int j = 0; j < i; j++) {
        free(dest[j]);
      }
      free(dest);
      return NULL;
    }
    memcpy(dest[i], bytes_array[i], len);
  }
  dest[n] = NULL;
  return dest;
}

static inline void
moonbit_pty__free_strings(char **strings) {
  for (int i = 0; strings[i] != NULL; i++) {
    free(strings[i]);
  }
  free(strings);
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_spawn(
  struct moonbit_pty *pty,
  int32_t efd,
  moonbit_bytes_t path,
  moonbit_bytes_t *argv,
  moonbit_bytes_t *envp,
  moonbit_bytes_t cwd
) {
  int er;
  int replica = pty->replica;

  int path_size = Moonbit_array_length(path) + 1;
  char *fork_path = malloc(path_size);
  if (!fork_path) {
    er = ENOMEM;
    goto fail_to_malloc_path;
  }
  memcpy(fork_path, path, path_size);

  char **fork_argv = moonbit_pty__dup_strings(argv);
  if (!fork_argv) {
    er = ENOMEM;
    goto fail_to_dup_argv;
  }
  char **fork_envp = moonbit_pty__dup_strings(envp);
  if (!fork_envp) {
    er = ENOMEM;
    goto fail_to_dup_envp;
  }

  int cwd_size = Moonbit_array_length(cwd) + 1;
  char *fork_cwd;
  if (cwd_size == 1) {
    fork_cwd = NULL;
  } else {
    fork_cwd = malloc(cwd_size);
    if (!fork_cwd) {
      er = ENOMEM;
      goto fail_to_malloc_cwd;
    }
    memcpy(fork_cwd, cwd, cwd_size);
  }

  pid_t pid = moonbit_pty__fork();
  if (pid == 0) {
    struct sigaction sa;
    sigemptyset(&sa.sa_mask);
    sigprocmask(SIG_SETMASK, &sa.sa_mask, NULL);
    sa.sa_handler = SIG_DFL;
    sa.sa_flags = 0;
    for (int i = 1; i < NSIG; i++) {
      sigaction(i, &sa, NULL);
    }

    if (efd < 3) {
      int nefd = fcntl(efd, F_DUPFD_CLOEXEC, 3);
      if (nefd < 0) {
        _exit(127);
      }
      efd = nefd;
    }

    if (replica < 3) {
      int n = fcntl(replica, F_DUPFD, 3);
      if (n < 0) {
        moonbit_pty__fork_fail(efd);
      }
      replica = n;
    }

    if (setsid() < 0) {
      moonbit_pty__fork_fail(efd);
    }
    if (ioctl(replica, TIOCSCTTY, 0) < 0) {
      moonbit_pty__fork_fail(efd);
    }
    if (dup2(replica, STDIN_FILENO) < 0 || dup2(replica, STDOUT_FILENO) < 0 ||
        dup2(replica, STDERR_FILENO) < 0) {
      moonbit_pty__fork_fail(efd);
    }
    if (fork_cwd && chdir(fork_cwd) < 0) {
      moonbit_pty__fork_fail(efd);
    }
    close(replica);
    execve(fork_path, fork_argv, fork_envp);
    moonbit_pty__fork_fail(efd);
  } else {
    /* `free` is not required to preserve `errno`, and the caller reads it right
     * after we hand back -1. */
    er = errno;
    free(fork_cwd);
    moonbit_pty__free_strings(fork_envp);
    moonbit_pty__free_strings(fork_argv);
    free(fork_path);
    if (pid < 0) {
      errno = er;
      return -1;
    }
    return pid;
  }

fail_to_malloc_cwd:
  moonbit_pty__free_strings(fork_envp);
fail_to_dup_envp:
  moonbit_pty__free_strings(fork_argv);
fail_to_dup_argv:
  free(fork_path);
fail_to_malloc_path:
  errno = er;
  return -1;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_resize(int32_t primary, int32_t rows, int32_t cols) {
  struct winsize ws = {
    .ws_row = rows,
    .ws_col = cols,
    .ws_xpixel = 0,
    .ws_ypixel = 0,
  };
  return ioctl(primary, TIOCSWINSZ, &ws);
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_hard_cancel_group(int32_t pid) {
  return kill(-pid, SIGKILL);
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_is_executable(const char *path) {
  struct stat st;
  return stat(path, &st) == 0 && S_ISREG(st.st_mode) && access(path, X_OK) == 0;
}
#endif
