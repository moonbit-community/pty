/*
 * Shared declarations for the PTY native stub.
 *
 * Platform implementation files include this header so clangd can parse them
 * directly, even though the build includes them through pty.c.
 */

#ifndef MOONBIT_PTY_INTERNAL_H
#define MOONBIT_PTY_INTERNAL_H

#include <assert.h>
#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/*
 * MoonBitPty is the payload MoonBit sees as `PtyHandle`. It lives in a
 * GC-managed Bytes allocation (value-as-Bytes pattern): plain POD state
 * with no finalizer — OS resources are released explicitly by Pty::close,
 * never by GC collection.
 */
typedef struct MoonBitPty {
#ifdef _WIN32
  void *hpc;            /* HPCON */
  /* Pipe HANDLE ownership uses INVALID_HANDLE_VALUE after release. */
  void *pipe_in_read;   /* stdin  pipe: read  end */
  void *pipe_in_write;  /* stdin  pipe: write end */
  void *pipe_out_read;  /* stdout pipe: read  end */
  void *pipe_out_write; /* stdout pipe: write end */
  /* Process and thread handles use NULL; (HANDLE)-1 means current process. */
  void *proc_handle;    /* child PROCESS_INFORMATION.hProcess */
  void *thread_handle;  /* child PROCESS_INFORMATION.hThread  */
#else
  /* File descriptor zero is valid, so ownership is tracked separately. */
  int master_fd;
  int32_t master_fd_is_open;
  int control_fd;
  int32_t control_fd_is_open;
  int slave_fd;
  int32_t slave_fd_is_open;
#endif
} MoonBitPty;

#endif
