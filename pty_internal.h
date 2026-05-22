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
 * the GC header; our payload is the platform handle.
 */
typedef struct {
  pty_handle_t handle;
} MoonBitPty;

#ifdef MOONBIT_PTY_IMPLEMENTATION
#define MOONBIT_PTY_INTERNAL static
#else
#define MOONBIT_PTY_INTERNAL extern
#endif

static void
moonbit_pty_close_impl(pty_handle_t *h);
MOONBIT_PTY_INTERNAL void
moonbit_pty_finalizer(void *ptr);
MOONBIT_PTY_INTERNAL void
moonbit_pty_init_handle(pty_handle_t *h);

#undef MOONBIT_PTY_INTERNAL

#endif
