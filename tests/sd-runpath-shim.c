/* ==========================================================================
 * TEST-ONLY LD_PRELOAD shim (sandbox battery, CP11) — NEVER used on a VPS.
 *
 * The container has no systemd PID 1, so `systemd --user` refuses to boot:
 * sd_booted() checks for the directory /run/systemd/system, which is created
 * by a real system manager at boot. /run/systemd is root-owned here, so the
 * unprivileged test user cannot create it.
 *
 * This shim rewrites every path that starts with /run/systemd to a writable
 * per-user directory (SD_SHIM_RUNPATH, default /tmp/sd-shim-run/systemd).
 * With /run/systemd/system present under the rewritten prefix, sd_booted()
 * succeeds and the user manager boots normally. Everything else about the
 * user manager is 100% genuine systemd: unit grammar, start/stop/restart,
 * StartLimitIntervalSec/StartLimitBurst, Restart=, hardening directives.
 *
 * Interposed calls: open, openat, stat, lstat, newfstatat, access,
 * faccessat, mkdir, opendir, rename, unlink, rmdir, truncate.
 * ==========================================================================
 */
#define _GNU_SOURCE
#include <stdlib.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>

#define FROM "/run/systemd"
static char to_path[512];
static int  to_ready = -1;   /* -1 uninit, 0 disabled, 1 enabled */

static const char *dest_base(void) {
    if (to_ready == -1) {
        const char *env = getenv("SD_SHIM_RUNPATH");
        snprintf(to_path, sizeof(to_path), "%s/systemd", env ? env : "/tmp/sd-shim-run");
        to_ready = 1;
    }
    return to_path;
}

/* returns 1 when `p` was rewritten into `out` */
static int rw(char *out, size_t outsz, const char *p) {
    size_t fl = strlen(FROM);
    if (!p || strncmp(p, FROM, fl) != 0) return 0;
    if (p[fl] != '\0' && p[fl] != '/') return 0;   /* only exact or prefix-dir */
    if (snprintf(out, outsz, "%s%s", dest_base(), p + fl) >= (int)outsz) return 0;
    return 1;
}

#define DEF_RETV(name, ret, args_, params_, pidx, flagsidx, varflags)          \
static ret (*real_##name) args_;                                               \
ret name params_ {                                                             \
    char alt[4096];                                                            \
    if (to_ready != 0 && rw(alt, sizeof(alt), p pidx)) {                       \
        if (!real_##name) real_##name = dlsym(RTLD_NEXT, #name);               \
        return real_##name alt;                                                \
    }                                                                          \
    if (!real_##name) real_##name = dlsym(RTLD_NEXT, #name);                   \
    return real_##name args_;                                                  \
}

/* --- path-based calls (path = first arg) --- */
static int (*real_access)(const char *, int);
int access(const char *p, int mode) {
    char alt[4096];
    if (rw(alt, sizeof(alt), p)) {
        if (!real_access) real_access = dlsym(RTLD_NEXT, "access");
        return real_access(alt, mode);
    }
    if (!real_access) real_access = dlsym(RTLD_NEXT, "access");
    return real_access(p, mode);
}

static int (*real_stat)(const char *, struct stat *);
int stat(const char *p, struct stat *st) {
    char alt[4096];
    if (rw(alt, sizeof(alt), p)) {
        if (!real_stat) real_stat = dlsym(RTLD_NEXT, "stat");
        return real_stat(alt, st);
    }
    if (!real_stat) real_stat = dlsym(RTLD_NEXT, "stat");
    return real_stat(p, st);
}

static int (*real_lstat)(const char *, struct stat *);
int lstat(const char *p, struct stat *st) {
    char alt[4096];
    if (rw(alt, sizeof(alt), p)) {
        if (!real_lstat) real_lstat = dlsym(RTLD_NEXT, "lstat");
        return real_lstat(alt, st);
    }
    if (!real_lstat) real_lstat = dlsym(RTLD_NEXT, "lstat");
    return real_lstat(p, st);
}

static int (*real_mkdir)(const char *, mode_t);
int mkdir(const char *p, mode_t m) {
    char alt[4096];
    if (rw(alt, sizeof(alt), p)) {
        if (!real_mkdir) real_mkdir = dlsym(RTLD_NEXT, "mkdir");
        return real_mkdir(alt, m);
    }
    if (!real_mkdir) real_mkdir = dlsym(RTLD_NEXT, "mkdir");
    return real_mkdir(p, m);
}

static int (*real_unlink)(const char *);
int unlink(const char *p) {
    char alt[4096];
    if (rw(alt, sizeof(alt), p)) {
        if (!real_unlink) real_unlink = dlsym(RTLD_NEXT, "unlink");
        return real_unlink(alt);
    }
    if (!real_unlink) real_unlink = dlsym(RTLD_NEXT, "unlink");
    return real_unlink(p);
}

static int (*real_rmdir)(const char *);
int rmdir(const char *p) {
    char alt[4096];
    if (rw(alt, sizeof(alt), p)) {
        if (!real_rmdir) real_rmdir = dlsym(RTLD_NEXT, "rmdir");
        return real_rmdir(alt);
    }
    if (!real_rmdir) real_rmdir = dlsym(RTLD_NEXT, "rmdir");
    return real_rmdir(p);
}

static DIR *(*real_opendir)(const char *);
DIR *opendir(const char *p) {
    char alt[4096];
    if (rw(alt, sizeof(alt), p)) {
        if (!real_opendir) real_opendir = dlsym(RTLD_NEXT, "opendir");
        return real_opendir(alt);
    }
    if (!real_opendir) real_opendir = dlsym(RTLD_NEXT, "opendir");
    return real_opendir(p);
}

static int (*real_open)(const char *, int, ...);
int open(const char *p, int flags, ...) {
    char alt[4096];
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap);
    }
    if (rw(alt, sizeof(alt), p)) {
        if (!real_open) real_open = dlsym(RTLD_NEXT, "open");
        return real_open(alt, flags, mode);
    }
    if (!real_open) real_open = dlsym(RTLD_NEXT, "open");
    return real_open(p, flags, mode);
}

static int (*real_openat)(int, const char *, int, ...);
int openat(int dirfd, const char *p, int flags, ...) {
    char alt[4096];
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap);
    }
    if (rw(alt, sizeof(alt), p)) {
        if (!real_openat) real_openat = dlsym(RTLD_NEXT, "openat");
        return real_openat(dirfd, alt, flags, mode);
    }
    if (!real_openat) real_openat = dlsym(RTLD_NEXT, "openat");
    return real_openat(dirfd, p, flags, mode);
}

static int (*real_newfstatat)(int, const char *, struct stat *, int);
int newfstatat(int dirfd, const char *p, struct stat *st, int flags) {
    char alt[4096];
    if (rw(alt, sizeof(alt), p)) {
        if (!real_newfstatat) real_newfstatat = dlsym(RTLD_NEXT, "newfstatat");
        return real_newfstatat(dirfd, alt, st, flags);
    }
    if (!real_newfstatat) real_newfstatat = dlsym(RTLD_NEXT, "newfstatat");
    return real_newfstatat(dirfd, p, st, flags);
}

static int (*real_faccessat)(int, const char *, int, int);
int faccessat(int dirfd, const char *p, int mode, int flags) {
    char alt[4096];
    if (rw(alt, sizeof(alt), p)) {
        if (!real_faccessat) real_faccessat = dlsym(RTLD_NEXT, "faccessat");
        return real_faccessat(dirfd, alt, mode, flags);
    }
    if (!real_faccessat) real_faccessat = dlsym(RTLD_NEXT, "faccessat");
    return real_faccessat(dirfd, p, mode, flags);
}

static int (*real_rename)(const char *, const char *);
int rename(const char *a, const char *b) {
    char alt[4096];
    const char *fa = a, *fb = b;
    char altb[4096];
    if (rw(alt, sizeof(alt), a)) fa = alt;
    if (rw(altb, sizeof(altb), b)) fb = altb;
    if (!real_rename) real_rename = dlsym(RTLD_NEXT, "rename");
    if (fa != a || fb != b) return real_rename(fa, fb);
    return real_rename(a, b);
}

static int (*real_truncate)(const char *, off_t);
int truncate(const char *p, off_t n) {
    char alt[4096];
    if (rw(alt, sizeof(alt), p)) {
        if (!real_truncate) real_truncate = dlsym(RTLD_NEXT, "truncate");
        return real_truncate(alt, n);
    }
    if (!real_truncate) real_truncate = dlsym(RTLD_NEXT, "truncate");
    return real_truncate(p, n);
}

/* --- unix socket connect(): rewrite /run/systemd/... journal socket -------
 * systemd logs to the journal socket at /run/systemd/journal/socket via
 * connect(); without this rewrite every user-manager message would be
 * silently dropped (no /dev/console, no /dev/kmsg in the sandbox).        */
#include <sys/socket.h>
#include <sys/un.h>
static int (*real_connect)(int, const struct sockaddr *, socklen_t);
int connect(int fd, const struct sockaddr *sa, socklen_t len) {
    if (sa && sa->sa_family == AF_UNIX && len > sizeof(sa_family_t)) {
        const struct sockaddr_un *u = (const struct sockaddr_un *) sa;
        if (u->sun_path[0] != '\0') {                 /* pathname, not abstract */
            char alt[4096];
            if (rw(alt, sizeof(alt), u->sun_path)) {
                struct sockaddr_un au;
                memset(&au, 0, sizeof(au));
                au.sun_family = AF_UNIX;
                strncpy(au.sun_path, alt, sizeof(au.sun_path) - 1);
                socklen_t al = (socklen_t)(offsetof(struct sockaddr_un, sun_path)
                                           + strlen(alt) + 1);
                if (!real_connect) real_connect = dlsym(RTLD_NEXT, "connect");
                return real_connect(fd, (const struct sockaddr *) &au, al);
            }
        }
    }
    if (!real_connect) real_connect = dlsym(RTLD_NEXT, "connect");
    return real_connect(fd, sa, len);
}

/* --- diagnostics: trace libc exit() with a backtrace (test-only) --------- */
#include <execinfo.h>
static void bt_print(const char *tag, int status) {
    fprintf(stderr, "=== SHIM: %s(%d) backtrace ===\n", tag, status);
    void *bt[48];
    int n = backtrace(bt, 48);
    backtrace_symbols_fd(bt, n, 2);
    fflush(stderr);
}
static void (*real_exit)(int) = NULL;
void exit(int status) {
    if (!real_exit) real_exit = dlsym(RTLD_NEXT, "exit");
    bt_print("exit", status);
    real_exit(status);
}
static void (*real__exit)(int) = NULL;
void _exit(int status) {
    if (!real__exit) real__exit = dlsym(RTLD_NEXT, "_exit");
    bt_print("_exit", status);
    real__exit(status);
}
static void (*real__Exit)(int) = NULL;
void _Exit(int status) {
    if (!real__Exit) real__Exit = dlsym(RTLD_NEXT, "_Exit");
    bt_print("_Exit", status);
    real__Exit(status);
}
