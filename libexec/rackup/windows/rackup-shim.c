/* rackup shim dispatcher for Windows.

   Each shim in %RACKUP_HOME%\shims (racket.exe, raco.exe, ...) picks the
   tool from its own file name, resolves the active toolchain the same
   way the Unix dispatcher script (shims.rkt) does, sets up the toolchain
   environment, and runs the real executable, passing the exit status
   through.  The shim named rackup.exe instead starts rackup itself.

   Windows has no exec(), so the shim stays alive as the parent: it
   ignores Ctrl+C (the child in the same console still receives it) and
   puts the child in a job object so that killing the shim kills the
   tool too.

   The code uses only kernel32 and no C runtime, so the binary is about
   12 KB and every shim can be a plain copy of it.  Build:
     x86_64-w64-mingw32-gcc -Os -s -nostdlib -fno-builtin -e shim_entry \
       -o rackup-shim.exe rackup-shim.c -lkernel32  */

#ifndef UNICODE
#define UNICODE
#endif

#include <windows.h>

#define RACKUP_UNINSTALL_CONFIRMED 10

/* ------------------------------------------------------------------ */
/* What the C runtime would otherwise provide.  GCC may emit calls to
   memset/memcpy for struct initialization even with -fno-builtin. */

void *memset(void *dst, int c, size_t n) {
  unsigned char *d = (unsigned char *)dst;
  while (n--) *d++ = (unsigned char)c;
  return dst;
}

void *memcpy(void *dst, const void *src, size_t n) {
  unsigned char *d = (unsigned char *)dst;
  const unsigned char *s = (const unsigned char *)src;
  while (n--) *d++ = *s++;
  return dst;
}

static int is_space(wchar_t c) { return c == L' ' || c == L'\t' || c == L'\r' || c == L'\n' || c == L'\v' || c == L'\f'; }
static int is_alnum(wchar_t c) { return (c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z'); }
static wchar_t to_lower(wchar_t c) { return (c >= L'A' && c <= L'Z') ? (wchar_t)(c - L'A' + L'a') : c; }

static size_t wlen(const wchar_t *s) { return (size_t)lstrlenW(s); }
static int weq(const wchar_t *a, const wchar_t *b) { return lstrcmpW(a, b) == 0; }

static void *xalloc(size_t bytes);

static wchar_t *wnew(size_t chars) { return (wchar_t *)xalloc((chars + 1) * sizeof(wchar_t)); }

static wchar_t *wdup(const wchar_t *s) {
  wchar_t *p = wnew(wlen(s));
  lstrcpyW(p, s);
  return p;
}

/* Concatenate strings; the list ends with NULL. */
static wchar_t *wcat(const wchar_t *first, ...) {
  va_list ap;
  size_t n = 0;
  const wchar_t *s;
  va_start(ap, first);
  for (s = first; s; s = va_arg(ap, const wchar_t *)) n += wlen(s);
  va_end(ap);
  wchar_t *out = wnew(n);
  va_start(ap, first);
  for (s = first; s; s = va_arg(ap, const wchar_t *)) lstrcatW(out, s);
  va_end(ap);
  return out;
}

static wchar_t *wnum(unsigned long v) {
  wchar_t buf[24];
  int i = 23;
  buf[i] = 0;
  do { buf[--i] = (wchar_t)(L'0' + v % 10); v /= 10; } while (v);
  return wdup(buf + i);
}

/* Write to stderr: UTF-16 to a console, UTF-8 to a file or pipe. */
static void eput(const wchar_t *s) {
  HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
  DWORD n = (DWORD)wlen(s), mode, written;
  if (h == NULL || h == INVALID_HANDLE_VALUE || n == 0) return;
  if (GetConsoleMode(h, &mode)) {
    WriteConsoleW(h, s, n, &written, NULL);
  } else {
    int bytes = WideCharToMultiByte(CP_UTF8, 0, s, (int)n, NULL, 0, NULL, NULL);
    char *buf = (char *)xalloc((size_t)bytes + 1);
    WideCharToMultiByte(CP_UTF8, 0, s, (int)n, buf, bytes, NULL, NULL);
    WriteFile(h, buf, (DWORD)bytes, &written, NULL);
  }
}

static void *xalloc(size_t bytes) {
  void *p = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, bytes);
  if (!p) {
    eput(L"rackup: out of memory\n");
    ExitProcess(1);
  }
  return p;
}

/* ------------------------------------------------------------------ */

static const wchar_t *racket_env_vars[] = {
  L"PLTCOLLECTS", L"PLTADDONDIR", L"PLTCOMPILEDROOTS",
  L"PLTUSERHOME", L"RACKET_XPATCH", L"PLT_COMPILED_FILE_CHECK", NULL
};

static const wchar_t *MARKER = L"_RACKUP_MANAGED_PLTCOMPILEDROOTS";

/* Join path parts with backslashes; the list ends with NULL. */
static wchar_t *path_join(const wchar_t *first, ...) {
  va_list ap;
  size_t n = 0;
  const wchar_t *s;
  va_start(ap, first);
  for (s = first; s; s = va_arg(ap, const wchar_t *)) n += wlen(s) + 1;
  va_end(ap);
  wchar_t *out = wnew(n);
  va_start(ap, first);
  for (s = first; s; s = va_arg(ap, const wchar_t *)) {
    size_t len = wlen(out);
    if (len > 0 && out[len - 1] != L'\\' && out[len - 1] != L'/') lstrcatW(out, L"\\");
    lstrcatW(out, s);
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
  wchar_t *v = wnew(n);
  GetEnvironmentVariableW(name, v, n);
  return v;
}

static int is_blank(const wchar_t *s) {
  if (!s) return 1;
  for (; *s; s++)
    if (!is_space(*s)) return 0;
  return 1;
}

static wchar_t *trim(wchar_t *s) {
  while (*s && is_space(*s)) s++;
  size_t n = wlen(s);
  while (n > 0 && is_space(s[n - 1])) s[--n] = 0;
  return s;
}

static int valid_id(const wchar_t *s) {
  if (!*s) return 0;
  for (; *s; s++)
    if (!(is_alnum(*s) || *s == L'.' || *s == L'_' || *s == L'-')) return 0;
  return 1;
}

/* Read a UTF-8 text file into a wide string, or NULL. */
static wchar_t *read_text_file(const wchar_t *p) {
  HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (h == INVALID_HANDLE_VALUE) return NULL;
  DWORD size = GetFileSize(h, NULL), got = 0;
  char *buf = (char *)xalloc((size_t)size + 1);
  BOOL ok = ReadFile(h, buf, size, &got, NULL);
  CloseHandle(h);
  if (!ok) return NULL;
  int wn = MultiByteToWideChar(CP_UTF8, 0, buf, (int)got, NULL, 0);
  wchar_t *w = wnew((size_t)wn);
  MultiByteToWideChar(CP_UTF8, 0, buf, (int)got, w, wn);
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

/* `arg` quoted for CommandLineToArgvW and the MS C runtime. */
static wchar_t *quote_arg(const wchar_t *arg) {
  wchar_t *out = wnew(2 * wlen(arg) + 2);
  wchar_t *o = out;
  *o++ = L'"';
  for (const wchar_t *s = arg;; s++) {
    size_t backslashes = 0, i;
    while (*s == L'\\') { backslashes++; s++; }
    if (!*s) {
      for (i = 0; i < backslashes * 2; i++) *o++ = L'\\';
      break;
    } else if (*s == L'"') {
      for (i = 0; i < backslashes * 2 + 1; i++) *o++ = L'\\';
      *o++ = L'"';
    } else {
      for (i = 0; i < backslashes; i++) *o++ = L'\\';
      *o++ = *s;
    }
  }
  *o++ = L'"';
  *o = 0;
  return out;
}

/* Run `exe` with the leading arguments `pre` (quoted here) followed by
   this process's own arguments, wait, and return its exit code. */
/* True when `p` is a GUI-subsystem executable (DrRacket.exe, GRacket.exe):
   the PE optional header's Subsystem field is IMAGE_SUBSYSTEM_WINDOWS_GUI.
   The field sits at the same offset in PE32 and PE32+ headers. */
static int is_gui_exe(const wchar_t *p) {
  HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL,
                         OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (h == INVALID_HANDLE_VALUE) return 0;
  unsigned char hdr[512];
  DWORD got = 0;
  int gui = 0;
  if (ReadFile(h, hdr, sizeof(hdr), &got, NULL) && got >= 0x40 && hdr[0] == 'M' && hdr[1] == 'Z') {
    DWORD pe = hdr[0x3C] | (hdr[0x3D] << 8) | (hdr[0x3E] << 16) | ((DWORD)hdr[0x3F] << 24);
    /* "PE\0\0", a 20-byte COFF header, then Subsystem at offset 68. */
    DWORD sub = pe + 4 + 20 + 68;
    if (pe < got - 4 && sub + 2 <= got && hdr[pe] == 'P' && hdr[pe + 1] == 'E' &&
        hdr[pe + 2] == 0 && hdr[pe + 3] == 0) {
      unsigned subsystem = hdr[sub] | (hdr[sub + 1] << 8);
      gui = subsystem == IMAGE_SUBSYSTEM_WINDOWS_GUI;
    }
  }
  CloseHandle(h);
  return gui;
}

/* Run `exe` with the arguments `pre` followed by this shim's own
   arguments.  A console program runs in a kill-on-close job and its exit
   code is returned.  A GUI program (`gui`) is started and left running,
   as when it is launched from Explorer, and the shim returns 0 at once,
   so a terminal is not held open by DrRacket. */
static DWORD run_program(const wchar_t *exe, const wchar_t **pre, int gui) {
  wchar_t *cmd = quote_arg(exe);
  for (; pre && *pre; pre++) cmd = wcat(cmd, L" ", quote_arg(*pre), NULL);
  cmd = wcat(cmd, command_line_tail(), NULL);

  if (gui) {
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    if (!CreateProcessW(exe, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
      eput(wcat(L"rackup: cannot run ", exe, L" (error ", wnum(GetLastError()), L")\n", NULL));
      return 126;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;
  }

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
  if (!CreateProcessW(exe, cmd, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &si, &pi)) {
    eput(wcat(L"rackup: cannot run ", exe, L" (error ", wnum(GetLastError()), L")\n", NULL));
    return 126;
  }
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
  return a && b && weq(a, b);
}

/* Apply the NAME=VALUE lines of a toolchain's env.txt, with the same
   PLTCOMPILEDROOTS precedence as env.sh: a user's value wins unless
   rackup itself exported it (it equals the marker). */
static void apply_env_file(const wchar_t *p) {
  wchar_t *next = read_text_file(p);
  if (!next) return;
  while (*next) {
    wchar_t *line = next;
    while (*next && *next != L'\r' && *next != L'\n') next++;
    while (*next == L'\r' || *next == L'\n') *next++ = 0;
    if (*line == L'#' || is_blank(line)) continue;
    wchar_t *eq = line;
    while (*eq && *eq != L'=') eq++;
    if (!*eq) continue;
    *eq = 0;
    const wchar_t *key = line, *val = eq + 1;
    if (weq(key, L"PLTCOMPILEDROOTS")) {
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
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW(path_join(addon, L"*", NULL), &fd);
  if (h == INVALID_HANDLE_VALUE) return NULL;
  wchar_t *found = NULL;
  do {
    if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
        !weq(fd.cFileName, L".") && !weq(fd.cFileName, L"..")) {
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
    if (!is_blank(val)) SetEnvironmentVariableW(wcat(L"_RACKUP_ORIG_", *v, NULL), val);
    SetEnvironmentVariableW(*v, NULL);
  }
  SetEnvironmentVariableW(L"RACKUP_HOME", home);

  DWORD code;
  wchar_t *core_exe = path_join(home, L"bin", L"rackup-core.exe", NULL);
  if (file_exists(core_exe)) {
    code = run_program(core_exe, NULL, 0);
  } else {
    wchar_t *current = follow_dir_pointer(path_join(home, L"runtime", L"current", NULL));
    wchar_t *bin = follow_dir_pointer(path_join(current, L"bin", NULL));
    wchar_t *racket = path_join(bin, L"racket.exe", NULL);
    if (!file_exists(racket)) {
      eput(wcat(L"rackup: hidden runtime is missing (", racket, L"); reinstall rackup\n", NULL));
      return 1;
    }
    wchar_t *addon = path_join(home, L"runtime", L"addon", NULL);
    CreateDirectoryW(addon, NULL);
    wchar_t *core = path_join(home, L"libexec", L"rackup-core.rkt", NULL);
    const wchar_t *pre[] = { L"-U", L"-A", addon, core, NULL };
    code = run_program(racket, pre, 0);
  }

  if (code == RACKUP_UNINSTALL_CONFIRMED) {
    /* The running shim (and maybe the shell's cwd) keeps files in
       RACKUP_HOME open, so delete it from a detached helper once this
       process has exited. */
    wchar_t *cmd = wcat(L"cmd.exe /d /c ping -n 3 127.0.0.1 >nul & rmdir /s /q \"", home, L"\"", NULL);
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    if (CreateProcessW(NULL, cmd, NULL, NULL, FALSE, DETACHED_PROCESS | CREATE_NO_WINDOW,
                       NULL, NULL, &si, &pi)) {
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
    } else {
      eput(wcat(L"rackup: could not remove ", home, L"; delete it by hand\n", NULL));
    }
    return 0;
  }
  return (int)code;
}

/* Dispatch for the shim at `shim` (its full path): pick the tool from
   the file name and run it. */
static int shim_main(const wchar_t *shim) {
  wchar_t *dir = wdup(shim);
  wchar_t *slash = dir;
  for (wchar_t *c = dir; *c; c++)
    if (*c == L'\\' || *c == L'/') slash = c;
  wchar_t *name = wdup(slash == dir ? dir : slash + 1);
  *slash = 0;
  size_t n = wlen(name);
  if (n > 4 && lstrcmpiW(name + n - 4, L".exe") == 0) name[n - 4] = 0;
  for (wchar_t *c = name; *c; c++) *c = to_lower(*c);

  wchar_t *home = get_env(L"RACKUP_HOME");
  if (is_blank(home)) {
    wchar_t *rel = path_join(dir, L"..", NULL);
    DWORD need = GetFullPathNameW(rel, 0, NULL, NULL);
    home = wnew(need);
    if (!GetFullPathNameW(rel, need, home, NULL)) home = rel;
  }

  if (weq(name, L"rackup")) return run_rackup(home);
  if (weq(name, L"rackup-shim")) {
    eput(L"rackup: this is rackup's shim dispatcher; run a tool through its shim instead\n");
    return 2;
  }
  if (weq(name, L"r")) name = wdup(L"racket");
  if (weq(name, L"dr")) name = wdup(L"drracket");

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
    eput(wcat(L"rackup: '", name, L"' is managed by rackup, but no active toolchain is configured.\n"
              L"Install one with: rackup install stable\n"
              L"Or select one with: rackup default <toolchain>\n"
              L"Inspect choices with: rackup list | rackup available --limit 20\n", NULL));
    return 2;
  }
  if (!valid_id(active)) {
    eput(wcat(L"rackup: invalid toolchain ID: ", active, L"\n", NULL));
    return 2;
  }

  wchar_t *tc_dir = path_join(home, L"toolchains", active, NULL);
  wchar_t *bin = follow_dir_pointer(path_join(tc_dir, L"bin", NULL));
  wchar_t *exe_name = wcat(name, L".exe", NULL);
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
      eput(wcat(L"rackup: executable '", name, L"' not found in toolchain '", active, L"'\n", NULL));
      if (!is_blank(env_tc)) {
        if (default_id)
          eput(wcat(L"rackup: active toolchain came from RACKUP_TOOLCHAIN and overrides default toolchain '",
                    default_id, L"'.\n", NULL));
        else
          eput(L"rackup: active toolchain came from RACKUP_TOOLCHAIN.\n");
        eput(L"Clear it with: rackup switch --unset\n");
      }
      eput(wcat(L"Try: rackup which ", name, L" --toolchain ", active, L"\n", NULL));
      return 127;
    }
    target = alt;
  }
  return (int)run_program(target, NULL, is_gui_exe(target));
}

/* The full path of the running executable. */
static wchar_t *self_path(void) {
  DWORD cap = MAX_PATH;
  for (;;) {
    wchar_t *buf = wnew(cap);
    DWORD n = GetModuleFileNameW(NULL, buf, cap);
    if (n == 0) {
      eput(L"rackup: cannot determine shim path\n");
      ExitProcess(1);
    }
    if (n < cap) return buf;
    cap *= 2;
  }
}

void shim_entry(void) {
  ExitProcess((UINT)shim_main(self_path()));
}

