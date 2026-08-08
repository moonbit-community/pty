/*
 * Shared declarations for the PTY native stub.
 *
 * Platform implementation files include this header so clangd can parse them
 * directly, even though the build includes them through pty.c.
 */

#ifndef MOONBIT_PTY_INTERNAL_H
#define MOONBIT_PTY_INTERNAL_H

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
} MoonBitPty;

#ifdef MOONBIT_PTY_IMPLEMENTATION
#define MOONBIT_PTY_INTERNAL static
#else
#define MOONBIT_PTY_INTERNAL extern
#endif

MOONBIT_PTY_INTERNAL void
moonbit_pty_init(MoonBitPty *pty);

#undef MOONBIT_PTY_INTERNAL

#endif
