/* rackup shim dispatcher for Windows.

   Every shim in %RACKUP_HOME%\shims (racket.exe, raco.exe, ...) is a
   copy of this program.  It picks the tool from its own file name,
   resolves the active toolchain the same way the Unix dispatcher script
   (shims.rkt) does, sets up the toolchain environment, and runs the real
   executable, passing the exit status through.  The copy named
   rackup.exe instead starts rackup itself.

   Windows has no exec(), so the shim stays alive as the parent: it
   ignores Ctrl+C (the child in the same console still receives it) and
   puts the child in a job object so that killing the shim kills the
   tool too.

   Build: x86_64-w64-mingw32-gcc -O2 -municode -o rackup-shim.exe rackup-shim.c
          (or: cl /O2 rackup-shim.c)  */

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define RACKUP_UNINSTALL_CONFIRMED 10

static const wchar_t *racket_env_vars[] = {
  L"PLTCOLLECTS", L"PLTADDONDIR", L"PLTCOMPILEDROOTS",
  L"PLTUSERHOME", L"RACKET_XPATCH", L"PLT_COMPILED_FILE_CHECK", NULL
};

static const wchar_t *MARKER = L"_RACKUP_MANAGED_PLTCOMPILEDROOTS";

static void die(int code, const wchar_t *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fputws(L"rackup: ", stderr);
  vfwprintf(stderr, fmt, ap);
  fputws(L"\n", stderr);
  va_end(ap);
  exit(code);
}

static wchar_t *xalloc(size_t n) {
  wchar_t *p = (wchar_t *)calloc(n, sizeof(wchar_t));
  if (!p) die(1, L"out of memory");
  return p;
}

static wchar_t *wdup(const wchar_t *s) {
  wchar_t *p = xalloc(wcslen(s) + 1);
  wcscpy(p, s);
  return p;
}

/* Join path parts with backslashes; the list ends with NULL. */
static wchar_t *path_join(const wchar_t *first, ...) {
  va_list ap;
  size_t n = wcslen(first) + 1;
  const wchar_t *s;
  va_start(ap, first);
  while ((s = va_arg(ap, const wchar_t *)) != NULL) n += wcslen(s) + 1;
  va_end(ap);
  wchar_t *out = xalloc(n + 1);
  wcscpy(out, first);
  va_start(ap, first);
  while ((s = va_arg(ap, const wchar_t *)) != NULL) {
    size_t len = wcslen(out);
    if (len > 0 && out[len - 1] != L'\\' && out[len - 1] != L'/') wcscat(out, L"\\");
    wcscat(out, s);
  }
  va_end(ap);
  return out;
}

static int file_exists(const wchar_t *p) {
  DWORD a = GetFileAttributesW(p);
  return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

static wchar_t *get_env(const wchar_t *name) {
  DWORD n = GetEnvironmentVariableW(name, NULL, 0);
  if (n == 0) return NULL;
  wchar_t *v = xalloc(n);
  GetEnvironmentVariableW(name, v, n);
  return v;
}

static int is_blank(const wchar_t *s) {
  if (!s) return 1;
  for (; *s; s++)
    if (!iswspace(*s)) return 0;
  return 1;
}

static wchar_t *trim(wchar_t *s) {
  while (*s && iswspace(*s)) s++;
  size_t n = wcslen(s);
  while (n > 0 && iswspace(s[n - 1])) s[--n] = 0;
  return s;
}

static int valid_id(const wchar_t *s) {
  if (!*s) return 0;
  for (; *s; s++)
    if (!(iswalnum(*s) || *s == L'.' || *s == L'_' || *s == L'-')) return 0;
  return 1;
}

/* Read a UTF-8 text file into a wide string, or NULL. */
static wchar_t *read_text_file(const wchar_t *p) {
  HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (h == INVALID_HANDLE_VALUE) return NULL;
  DWORD size = GetFileSize(h, NULL);
  char *buf = (char *)calloc(size + 1, 1);
  DWORD got = 0;
  if (!buf || !ReadFile(h, buf, size, &got, NULL)) {
    CloseHandle(h);
    free(buf);
    return NULL;
  }
  CloseHandle(h);
  int wn = MultiByteToWideChar(CP_UTF8, 0, buf, (int)got, NULL, 0);
  wchar_t *w = xalloc(wn + 1);
  MultiByteToWideChar(CP_UTF8, 0, buf, (int)got, w, wn);
  free(buf);
  return w;
}

/* A directory pointer (see replace-dir-pointer! in fs.rkt) is a file
   holding the target directory's path; a real directory is its own
   target. */
static wchar_t *follow_dir_pointer(const wchar_t *p) {
  if (file_exists(p)) {
    wchar_t *s = read_text_file(p);
    if (s) {
      wchar_t *t = trim(s);
      if (*t) return wdup(t);
    }
  }
  return wdup(p);
}

/* The directory holding this executable, and its tool name: the file
   name without ".exe", lowercased. */
static void self_location(wchar_t **dir_out, wchar_t **name_out) {
  DWORD cap = MAX_PATH;
  wchar_t *buf = NULL;
  for (;;) {
    buf = xalloc(cap);
    DWORD n = GetModuleFileNameW(NULL, buf, cap);
    if (n == 0) die(1, L"cannot determine shim path");
    if (n < cap) break;
    free(buf);
    cap *= 2;
  }
  wchar_t *slash = wcsrchr(buf, L'\\');
  wchar_t *base = slash ? slash + 1 : buf;
  wchar_t *name = wdup(base);
  size_t n = wcslen(name);
  if (n > 4 && _wcsicmp(name + n - 4, L".exe") == 0) name[n - 4] = 0;
  for (wchar_t *c = name; *c; c++) *c = towlower(*c);
  if (slash) *slash = 0;
  *dir_out = buf;
  *name_out = name;
}

/* The arguments part of this process's command line, verbatim (with
   its leading space), so quoting reaches the tool unchanged. */
static const wchar_t *command_line_tail(void) {
  const wchar_t *p = GetCommandLineW();
  if (*p == L'"') {
    p++;
    while (*p && *p != L'"') p++;
    if (*p) p++;
  } else {
    while (*p && *p != L' ' && *p != L'\t') p++;
  }
  return p;
}

/* Append `arg` to `cmd` quoted for CommandLineToArgvW/the MS C runtime. */
static void append_quoted(wchar_t **cmd, size_t *cap, const wchar_t *arg) {
  size_t need = wcslen(*cmd) + 2 * wcslen(arg) + 4;
  if (need > *cap) {
    *cap = need * 2;
    wchar_t *n = xalloc(*cap);
    wcscpy(n, *cmd);
    free(*cmd);
    *cmd = n;
  }
  wchar_t *o = *cmd + wcslen(*cmd);
  if (o != *cmd) *o++ = L' ';
  *o++ = L'"';
  for (const wchar_t *s = arg;; s++) {
    size_t backslashes = 0;
    while (*s == L'\\') { backslashes++; s++; }
    if (!*s) {
      for (size_t i = 0; i < backslashes * 2; i++) *o++ = L'\\';
      break;
    } else if (*s == L'"') {
      for (size_t i = 0; i < backslashes * 2 + 1; i++) *o++ = L'\\';
      *o++ = L'"';
    } else {
      for (size_t i = 0; i < backslashes; i++) *o++ = L'\\';
      *o++ = *s;
    }
  }
  *o++ = L'"';
  *o = 0;
}

/* Run `exe` with the leading arguments `pre` (quoted here) followed by
   this process's own arguments, wait, and return its exit code. */
static DWORD run(const wchar_t *exe, const wchar_t **pre) {
  size_t cap = 1024;
  wchar_t *cmd = xalloc(cap);
  append_quoted(&cmd, &cap, exe);
  for (; pre && *pre; pre++) append_quoted(&cmd, &cap, *pre);
  const wchar_t *tail = command_line_tail();
  wchar_t *full = xalloc(wcslen(cmd) + wcslen(tail) + 1);
  wcscpy(full, cmd);
  wcscat(full, tail);

  HANDLE job = CreateJobObjectW(NULL, NULL);
  if (job) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
    memset(&info, 0, sizeof(info));
    info.BasicLimitInformation.LimitFlags =
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
    SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof(info));
  }

  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  memset(&si, 0, sizeof(si));
  si.cb = sizeof(si);
  if (!CreateProcessW(exe, full, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &si, &pi))
    die(126, L"cannot run %ls (error %lu)", exe, GetLastError());
  if (job) AssignProcessToJobObject(job, pi.hProcess);
  SetConsoleCtrlHandler(NULL, TRUE); /* the child handles Ctrl+C */
  ResumeThread(pi.hThread);
  CloseHandle(pi.hThread);
  WaitForSingleObject(pi.hProcess, INFINITE);
  DWORD code = 1;
  GetExitCodeProcess(pi.hProcess, &code);
  CloseHandle(pi.hProcess);
  return code;
}

static int env_equal(const wchar_t *a, const wchar_t *b) {
  return a && b && wcscmp(a, b) == 0;
}

/* Apply the NAME=VALUE lines of a toolchain's env.txt, with the same
   PLTCOMPILEDROOTS precedence as env.sh: a user's value wins unless
   rackup itself exported it (it equals the marker). */
static void apply_env_file(const wchar_t *p) {
  wchar_t *text = read_text_file(p);
  if (!text) return;
  wchar_t *next = text;
  while (*next) {
    wchar_t *line = next;
    size_t len = wcscspn(line, L"\r\n");
    next = line + len;
    while (*next == L'\r' || *next == L'\n') *next++ = 0;
    line[len] = 0;
    if (*line == L'#' || is_blank(line)) continue;
    wchar_t *eq = wcschr(line, L'=');
    if (!eq) continue;
    *eq = 0;
    const wchar_t *key = line, *val = eq + 1;
    if (wcscmp(key, L"PLTCOMPILEDROOTS") == 0) {
      wchar_t *cur = get_env(key), *mark = get_env(MARKER);
      if (is_blank(cur) || env_equal(cur, mark)) {
        SetEnvironmentVariableW(key, val);
        SetEnvironmentVariableW(MARKER, val);
      }
    } else {
      SetEnvironmentVariableW(key, val);
    }
  }
}

/* $PLTADDONDIR\bin\<name>.exe, then $PLTADDONDIR\*\bin\<name>.exe. */
static wchar_t *find_addon_exe(const wchar_t *addon, const wchar_t *exe_name) {
  wchar_t *direct = path_join(addon, L"bin", exe_name, NULL);
  if (file_exists(direct)) return direct;
  wchar_t *pattern = path_join(addon, L"*", NULL);
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW(pattern, &fd);
  if (h == INVALID_HANDLE_VALUE) return NULL;
  wchar_t *found = NULL;
  do {
    if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
        wcscmp(fd.cFileName, L".") != 0 && wcscmp(fd.cFileName, L"..") != 0) {
      wchar_t *c = path_join(addon, fd.cFileName, L"bin", exe_name, NULL);
      if (file_exists(c)) { found = c; break; }
    }
  } while (FindNextFileW(h, &fd));
  FindClose(h);
  return found;
}

static int run_rackup(const wchar_t *home) {
  /* Save the user's Racket variables for `rackup run`, then clear them
     so rackup's own runtime is not affected (as bin/rackup does). */
  for (const wchar_t **v = racket_env_vars; *v; v++) {
    wchar_t *val = get_env(*v);
    if (!is_blank(val)) {
      wchar_t saved[128];
      swprintf(saved, 128, L"_RACKUP_ORIG_%ls", *v);
      SetEnvironmentVariableW(saved, val);
    }
    SetEnvironmentVariableW(*v, NULL);
  }
  SetEnvironmentVariableW(L"RACKUP_HOME", home);

  DWORD code;
  wchar_t *core_exe = path_join(home, L"bin", L"rackup-core.exe", NULL);
  if (file_exists(core_exe)) {
    code = run(core_exe, NULL);
  } else {
    wchar_t *current = follow_dir_pointer(path_join(home, L"runtime", L"current", NULL));
    wchar_t *bin = follow_dir_pointer(path_join(current, L"bin", NULL));
    wchar_t *racket = path_join(bin, L"racket.exe", NULL);
    if (!file_exists(racket))
      die(1, L"hidden runtime is missing (%ls); reinstall rackup", racket);
    wchar_t *addon = path_join(home, L"runtime", L"addon", NULL);
    CreateDirectoryW(addon, NULL);
    wchar_t *core = path_join(home, L"libexec", L"rackup-core.rkt", NULL);
    const wchar_t *pre[] = { L"-U", L"-A", addon, core, NULL };
    code = run(racket, pre);
  }

  if (code == RACKUP_UNINSTALL_CONFIRMED) {
    /* The running shim (and maybe the shell's cwd) keeps files in
       RACKUP_HOME open, so delete it from a detached helper once this
       process has exited. */
    size_t n = wcslen(home) + 128;
    wchar_t *cmd = xalloc(n);
    swprintf(cmd, n, L"cmd.exe /d /c ping -n 3 127.0.0.1 >nul & rmdir /s /q \"%ls\"", home);
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    if (CreateProcessW(NULL, cmd, NULL, NULL, FALSE, DETACHED_PROCESS | CREATE_NO_WINDOW,
                       NULL, NULL, &si, &pi)) {
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
    } else {
      fwprintf(stderr, L"rackup: could not remove %ls; delete it by hand\n", home);
    }
    return 0;
  }
  return (int)code;
}

int wmain(int argc, wchar_t **argv) {
  (void)argc;
  (void)argv;
  wchar_t *self_dir, *name;
  self_location(&self_dir, &name);

  wchar_t *home = get_env(L"RACKUP_HOME");
  if (is_blank(home)) {
    home = path_join(self_dir, L"..", NULL);
    wchar_t full[MAX_PATH * 4];
    if (GetFullPathNameW(home, MAX_PATH * 4, full, NULL)) home = wdup(full);
  }

  if (wcscmp(name, L"rackup") == 0) return run_rackup(home);
  if (wcscmp(name, L"rackup-shim") == 0)
    die(2, L"this is rackup's shim dispatcher; run a tool through its shim instead");
  if (wcscmp(name, L"r") == 0) name = wdup(L"racket");
  if (wcscmp(name, L"dr") == 0) name = wdup(L"drracket");

  /* Active toolchain: RACKUP_TOOLCHAIN, else the default.  A blank
     RACKUP_TOOLCHAIN counts as unset, and an invalid default as none. */
  wchar_t *env_tc = get_env(L"RACKUP_TOOLCHAIN");
  wchar_t *active = is_blank(env_tc) ? NULL : trim(env_tc);
  wchar_t *default_id = NULL;
  wchar_t *dtext = read_text_file(path_join(home, L"state", L"default-toolchain", NULL));
  if (dtext) {
    default_id = trim(dtext);
    if (!valid_id(default_id)) default_id = NULL;
  }
  if (!active) active = default_id;
  if (!active) {
    fwprintf(stderr,
             L"rackup: '%ls' is managed by rackup, but no active toolchain is configured.\n"
             L"Install one with: rackup install stable\n"
             L"Or select one with: rackup default <toolchain>\n"
             L"Inspect choices with: rackup list | rackup available --limit 20\n", name);
    return 2;
  }
  if (!valid_id(active)) die(2, L"invalid toolchain ID: %ls", active);

  wchar_t *tc_dir = path_join(home, L"toolchains", active, NULL);
  wchar_t *bin = follow_dir_pointer(path_join(tc_dir, L"bin", NULL));
  wchar_t *exe_name = xalloc(wcslen(name) + 5);
  wcscpy(exe_name, name);
  wcscat(exe_name, L".exe");
  wchar_t *target = path_join(bin, exe_name, NULL);

  /* The addon dir comes from the toolchain, never from the shell, and a
     PLTCOMPILEDROOTS that an enclosing rackup launch exported is
     dropped (see the Unix dispatcher). */
  SetEnvironmentVariableW(L"PLTADDONDIR", NULL);
  {
    wchar_t *roots = get_env(L"PLTCOMPILEDROOTS"), *mark = get_env(MARKER);
    if (!is_blank(roots) && env_equal(roots, mark)) {
      SetEnvironmentVariableW(L"PLTCOMPILEDROOTS", NULL);
      SetEnvironmentVariableW(MARKER, NULL);
    }
  }
  apply_env_file(path_join(tc_dir, L"env.txt", NULL));
  wchar_t *addon = get_env(L"PLTADDONDIR");
  if (is_blank(addon)) {
    addon = path_join(home, L"addons", active, NULL);
    SetEnvironmentVariableW(L"PLTADDONDIR", addon);
  }

  if (!file_exists(target)) {
    wchar_t *alt = find_addon_exe(addon, exe_name);
    if (!alt) {
      fwprintf(stderr, L"rackup: executable '%ls' not found in toolchain '%ls'\n", name, active);
      if (!is_blank(env_tc)) {
        if (default_id)
          fwprintf(stderr, L"rackup: active toolchain came from RACKUP_TOOLCHAIN and overrides default toolchain '%ls'.\n", default_id);
        else
          fwprintf(stderr, L"rackup: active toolchain came from RACKUP_TOOLCHAIN.\n");
        fwprintf(stderr, L"Clear it with: rackup switch --unset\n");
      }
      fwprintf(stderr, L"Try: rackup which %ls --toolchain %ls\n", name, active);
      return 127;
    }
    target = alt;
  }
  return (int)run(target, NULL);
}
