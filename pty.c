#if !defined(_WIN32)

/* `grantpt`, `unlockpt` and `ptsname_r` are only declared by glibc's
 * <stdlib.h> under _GNU_SOURCE, which has to be defined before any system
 * header pulls in <features.h>. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/ttycom.h>
#endif

#include "moonbit.h"

struct moonbit_pty_unix {
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
moonbit_pty_unix_set_termios(struct termios *t) {
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
moonbit_pty_unix_fork(void) {
  if (&__fork == NULL) {
    errno = ENOSYS;
    return -1;
  }
  return __fork();
}

#else

static inline pid_t
moonbit_pty_unix_fork(void) {
  return fork();
}

#endif

static inline int32_t
moonbit_pty_unix_dupfd_cloexec_3(int32_t fd) {
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

static inline int
moonbit_pty_unix_openpt(const char *path, int oflags) {
  int fd = open(path, oflags);
  if (fd < 0) {
    return -1;
  }
  return moonbit_pty_unix_dupfd_cloexec_3(fd);
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_unix_open(
  struct moonbit_pty_unix *pty,
  int32_t rows,
  int32_t cols
) {
  int saved_errno;

  int primary = moonbit_pty_unix_openpt(
    "/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC | O_NONBLOCK
  );
  if (primary < 0) {
    saved_errno = errno;
    goto fail_to_open_primary;
  }

  if (grantpt(primary) != 0) {
    saved_errno = errno;
    goto fail_to_grant_pt;
  }
  if (unlockpt(primary) != 0) {
    saved_errno = errno;
    goto fail_to_unlock_pt;
  }

  char nm[128];
  if (ptsname_r(primary, nm, sizeof(nm)) != 0) {
    saved_errno = errno;
    goto fail_to_get_ptsname;
  }

  int replica = moonbit_pty_unix_openpt(nm, O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (replica < 0) {
    saved_errno = errno;
    goto fail_to_open_replica;
  }

  struct termios t;
  moonbit_pty_unix_set_termios(&t);
  if (tcsetattr(replica, TCSAFLUSH, &t) != 0) {
    saved_errno = errno;
    goto fail_to_set_termios;
  }

  struct winsize ws = {
    .ws_row = rows,
    .ws_col = cols,
    .ws_xpixel = 0,
    .ws_ypixel = 0,
  };
  if (ioctl(replica, TIOCSWINSZ, &ws) != 0) {
    saved_errno = errno;
    goto fail_to_set_winsize;
  }
  pty->primary = primary;
  pty->replica = replica;
  return 0;

fail_to_set_winsize:
fail_to_set_termios:
  close(replica);
fail_to_open_replica:
fail_to_get_ptsname:
fail_to_unlock_pt:
fail_to_grant_pt:
  close(primary);
fail_to_open_primary:
  errno = saved_errno;
  return -1;
}

/**
 * Create the spawn error pipe. Both ends are CLOEXEC; the read end is left
 * BLOCKING on purpose. A blocking fd makes moonbitlang/async read it through
 * the worker thread pool instead of registering it with kqueue/epoll. On
 * macOS, a kqueue knote on a pipe fd that is armed while the process fork()s
 * can miss its final EOF edge (kevent never fires even after every write end
 * is closed), which deadlocks `spawn` in `error_reader.read_all()`.
 */
MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_unix_create_error_pipe(int32_t *fds) {
  if (pipe(fds) < 0) {
    return -1;
  }
  if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 ||
      fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0) {
    int er = errno;
    close(fds[0]);
    close(fds[1]);
    errno = er;
    return -1;
  }
  return 0;
}

#define MOONBIT_PTY__NORETURN __attribute__((noreturn))

static inline void MOONBIT_PTY__NORETURN
moonbit_pty_unix_write_error_exit(int32_t efd, int32_t er) {
  ssize_t n = write(efd, &er, sizeof(er));
  (void)n;
  _exit(127);
}

static inline char **
moonbit_pty_unix_copy_strings(moonbit_bytes_t *bytes_array, int32_t n) {
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
moonbit_pty_unix_free_strings(char **strings) {
  for (int i = 0; strings[i] != NULL; i++) {
    free(strings[i]);
  }
  free(strings);
}

/**
 * `execve`, retrying while the failure is ETXTBSY. The busy state is
 * transient when the file was just written: it clears as soon as the last
 * write descriptor is gone (cf. cmd/go's retry loop, golang.org/issue/22315;
 * we saw it exactly once, on GitHub's ubuntu runner, and could not reproduce
 * it anywhere else — see TODO.md). The retry is bounded so a file genuinely
 * held open for writing still fails, roughly a second later.
 *
 * The trailing call is the attempt after the final sleep, and also
 * guarantees `errno` was set by `execve` rather than by a
 * signal-interrupted `nanosleep`.
 */
static inline int
moonbit_pty_unix_execve_ignore_etxtbsy(
  const char *path,
  char *const *argv,
  char *const *envp
) {
  struct timespec delay = {0, 50 * 1000 * 1000}; /* 50ms */
  for (int attempt = 0; attempt < 20; attempt++) {
    execve(path, argv, envp);
    if (errno != ETXTBSY) {
      break;
    }
    nanosleep(&delay, NULL);
  }
  execve(path, argv, envp);
  return -1;
}

static inline int
moonbit_pty_unix_execve_candidates(
  char **path,
  char *const *argv,
  char *const *envp
) {
  int execve_errno = ENOENT;
  for (int i = 0; path[i]; i++) {
    moonbit_pty_unix_execve_ignore_etxtbsy(path[i], argv, envp);
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
  return -1;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_unix_spawn(
  struct moonbit_pty_unix *pty,
  int32_t efd,
  moonbit_bytes_t *path,
  moonbit_bytes_t *argv,
  moonbit_bytes_t *envp,
  moonbit_bytes_t cwd
) {
  int saved_errno;
  int replica = pty->replica;

  int32_t path_size = Moonbit_array_length(path);
  char **fork_path = moonbit_pty_unix_copy_strings(path, path_size);
  if (!fork_path) {
    saved_errno = ENOMEM;
    goto fail_to_dup_path;
  }

  int32_t argv_size = Moonbit_array_length(argv);
  char **fork_argv = moonbit_pty_unix_copy_strings(argv, argv_size);
  if (!fork_argv) {
    saved_errno = ENOMEM;
    goto fail_to_dup_argv;
  }

  int32_t envp_size = Moonbit_array_length(envp);
  char **fork_envp = moonbit_pty_unix_copy_strings(envp, envp_size);
  if (!fork_envp) {
    saved_errno = ENOMEM;
    goto fail_to_dup_envp;
  }

  int cwd_size = Moonbit_array_length(cwd) + 1;
  char *fork_cwd;
  if (cwd_size == 1) {
    fork_cwd = NULL;
  } else {
    fork_cwd = malloc(cwd_size);
    if (!fork_cwd) {
      saved_errno = ENOMEM;
      goto fail_to_malloc_cwd;
    }
    memcpy(fork_cwd, cwd, cwd_size);
  }

  pid_t pid = moonbit_pty_unix_fork();
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
        moonbit_pty_unix_write_error_exit(efd, errno);
      }
      replica = n;
    }

    if (setsid() < 0) {
      moonbit_pty_unix_write_error_exit(efd, errno);
    }
    if (ioctl(replica, TIOCSCTTY, 0) < 0) {
      moonbit_pty_unix_write_error_exit(efd, errno);
    }
    if (dup2(replica, STDIN_FILENO) < 0 || dup2(replica, STDOUT_FILENO) < 0 ||
        dup2(replica, STDERR_FILENO) < 0) {
      moonbit_pty_unix_write_error_exit(efd, errno);
    }
    if (fork_cwd && chdir(fork_cwd) < 0) {
      moonbit_pty_unix_write_error_exit(efd, errno);
    }
    close(replica);
    moonbit_pty_unix_execve_candidates(fork_path, fork_argv, fork_envp);
    moonbit_pty_unix_write_error_exit(efd, errno);
  } else {
    /* `free` is not required to preserve `errno`, and the caller reads it right
     * after we hand back -1. */
    saved_errno = errno;
    free(fork_cwd);
    moonbit_pty_unix_free_strings(fork_envp);
    moonbit_pty_unix_free_strings(fork_argv);
    moonbit_pty_unix_free_strings(fork_path);
    if (pid < 0) {
      errno = saved_errno;
      return -1;
    }
    return pid;
  }

fail_to_malloc_cwd:
  moonbit_pty_unix_free_strings(fork_envp);
fail_to_dup_envp:
  moonbit_pty_unix_free_strings(fork_argv);
fail_to_dup_argv:
  moonbit_pty_unix_free_strings(fork_path);
fail_to_dup_path:
  errno = saved_errno;
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
moonbit_pty_unix_kill_group(int32_t pid) {
  return kill(-pid, SIGKILL);
}
#endif

#if defined(_WIN32)

#include <windows.h>

#include <consoleapi.h>
#include <corecrt_search.h>
#include <errhandlingapi.h>
#include <fileapi.h>
#include <handleapi.h>
#include <jobapi2.h>
#include <minwindef.h>
#include <processthreadsapi.h>
#include <stdint.h>
#include <winbase.h>
#include <wincontypes.h>
#include <winerror.h>
#include <winnt.h>

#include "moonbit.h"

MOONBIT_FFI_EXPORT
HANDLE
moonbit_pty_win32_get_invalid_handle(void) { return INVALID_HANDLE_VALUE; }

struct moonbit_pty_win32 {
  HANDLE hInputWriter;
  HANDLE hOutputReader;
  HPCON hpc;
};

struct moonbit_pty_win32_session {
  HANDLE hProcess;
  HANDLE job;
};

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_win32_open(
  struct moonbit_pty_win32 *pty,
  int32_t rows,
  int32_t cols
) {
  DWORD dwLastError;
  HANDLE hInputReader = INVALID_HANDLE_VALUE;
  HANDLE hOutputWriter = INVALID_HANDLE_VALUE;
  if (!CreatePipe(&hInputReader, &pty->hInputWriter, NULL, 0)) {
    dwLastError = GetLastError();
    goto fail_to_create_input_pipe;
  }
  if (!CreatePipe(&pty->hOutputReader, &hOutputWriter, NULL, 0)) {
    dwLastError = GetLastError();
    goto fail_to_create_output_pipe;
  }
  COORD size = {(SHORT)cols, (SHORT)rows};
  HRESULT hr =
    CreatePseudoConsole(size, hInputReader, hOutputWriter, 0, &pty->hpc);
  if (FAILED(hr)) {
    dwLastError = HRESULT_CODE(hr);
    goto fail_to_create_pseudo_console;
  }
  CloseHandle(hInputReader);
  CloseHandle(hOutputWriter);
  return 0;

fail_to_create_pseudo_console:
  CloseHandle(pty->hOutputReader);
  CloseHandle(hOutputWriter);
fail_to_create_output_pipe:
  CloseHandle(hInputReader);
  CloseHandle(pty->hInputWriter);
fail_to_create_input_pipe:
  SetLastError(dwLastError);
  return -1;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_win32_spawn(
  HPCON hpc,
  struct moonbit_pty_win32_session *session,
  moonbit_string_t cmd,
  moonbit_string_t app,
  moonbit_string_t env,
  moonbit_string_t cwd
) {
  DWORD dwLastError;
  BOOL ok;

  STARTUPINFOEXW si = {0};
  si.StartupInfo.cb = sizeof(si);
  si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  SIZE_T lpSize;
  InitializeProcThreadAttributeList(NULL, 1, 0, &lpSize);
  si.lpAttributeList = malloc(lpSize);
  if (!si.lpAttributeList) {
    dwLastError = ERROR_OUTOFMEMORY;
    goto fail_to_malloc_attribute_list;
  }
  ok = InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &lpSize);
  if (!ok) {
    dwLastError = GetLastError();
    goto fail_to_initialize_attribute_list;
  }
  ok = UpdateProcThreadAttribute(
    si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc,
    sizeof(hpc), NULL, NULL
  );
  if (!ok) {
    dwLastError = GetLastError();
    goto fail_to_update_proc_thread_attribute;
  }

  HANDLE job = CreateJobObjectW(NULL, NULL);
  if (!job) {
    dwLastError = GetLastError();
    goto fail_to_create_job_object;
  }

  JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = {0};
  info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  ok = SetInformationJobObject(
    job, JobObjectExtendedLimitInformation, &info, sizeof(info)
  );
  if (!ok) {
    dwLastError = GetLastError();
    goto fail_to_set_infomation_job_object;
  }

  if (Moonbit_array_length(cwd) == 0) {
    cwd = NULL;
  }

  PROCESS_INFORMATION pi = {0};
  ok = CreateProcessW(
    app, cmd, NULL, NULL, FALSE,
    EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT |
      CREATE_SUSPENDED,
    env, cwd, &si.StartupInfo, &pi
  );
  if (!ok) {
    dwLastError = GetLastError();
    goto fail_to_create_process;
  }
  DeleteProcThreadAttributeList(si.lpAttributeList);
  free(si.lpAttributeList);

  ok = AssignProcessToJobObject(job, pi.hProcess);
  if (!ok) {
    CloseHandle(job);
    job = INVALID_HANDLE_VALUE;
  }

  ResumeThread(pi.hThread);
  CloseHandle(pi.hThread);

  session->hProcess = pi.hProcess;
  session->job = job;
  return pi.dwProcessId;

fail_to_create_process:
fail_to_set_infomation_job_object:
  CloseHandle(job);
fail_to_create_job_object:
fail_to_update_proc_thread_attribute:
  DeleteProcThreadAttributeList(si.lpAttributeList);
fail_to_initialize_attribute_list:
  free(si.lpAttributeList);
fail_to_malloc_attribute_list:
  SetLastError(dwLastError);
  return -1;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_win32_resize(HPCON hpc, int32_t rows, int32_t cols) {
  COORD size = {(SHORT)cols, (SHORT)rows};
  HRESULT hr = ResizePseudoConsole(hpc, size);
  if (FAILED(hr)) {
    SetLastError(HRESULT_CODE(hr));
    return -1;
  } else {
    return 0;
  }
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_pty_win32_file_exists(moonbit_string_t path) {
  DWORD attrs = GetFileAttributesW(path);
  return attrs != INVALID_FILE_ATTRIBUTES &&
         !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

MOONBIT_FFI_EXPORT
moonbit_string_t
moonbit_pty_win32_get_full_path_name(moonbit_string_t path) {
  WCHAR buf[32768];
  DWORD n = GetFullPathNameW(path, 32768, buf, NULL);
  if (n == 0 || n >= 32768) {
    return moonbit_empty_int16_array;
  }
  moonbit_string_t result = moonbit_make_string(n, 0);
  memcpy(result, buf, n * sizeof(WCHAR));
  return result;
}

#endif
