#ifndef CPTY_HELPER_H
#define CPTY_HELPER_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    pid_t pid;
    int master_fd;
    int error_number;
} CPTYSpawnResult;

/// Spawns `executable` with `argv` in a new session with a controlling pseudo-terminal.
/// On success: `pid > 0`, `master_fd >= 0`, `error_number == 0`.
/// On failure: `pid == -1`, `master_fd == -1`, `error_number` holds `errno`.
CPTYSpawnResult cpty_spawn(const char *executable, char * const argv[]);

/// Waits for `pid` to exit without reaping it (`WNOWAIT`), retrying on `EINTR`.
/// Returns 0 on success or -1 on error (preserving `errno`).
int cpty_wait_no_reap(pid_t pid);

/// Reaps `pid` via `waitpid` and decodes its exit code (`WEXITSTATUS` or `128 + WTERMSIG`).
/// Returns 0 on success or -1 on error.
int cpty_reap_exit_status(pid_t pid, int *out_exit_code);

#ifdef __cplusplus
}
#endif

#endif
