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
moonbit_pty_win32_get_invalid_handle(void) {
  return INVALID_HANDLE_VALUE;
}

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
