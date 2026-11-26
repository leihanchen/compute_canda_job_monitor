#include "CPTYHelper.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

static void cpty_close_if_valid(int fd) {
    if (fd >= 0) {
        close(fd);
    }
}

static void cpty_child_fail(int err_fd, int fallback_err) __attribute__((noreturn));
static void cpty_child_fail(int err_fd, int fallback_err) {
    int err = errno ? errno : fallback_err;
    ssize_t ignored = write(err_fd, &err, sizeof(err));
    (void)ignored;
    _exit(127);
}

CPTYSpawnResult cpty_spawn(const char *executable, char * const argv[]) {
    if (executable == NULL || argv == NULL || argv[0] == NULL) {
        return (CPTYSpawnResult){ -1, -1, EINVAL };
    }

    int master_fd = -1;
    int slave_fd = -1;
    struct winsize ws = {
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0
    };

    if (openpty(&master_fd, &slave_fd, NULL, NULL, &ws) == -1) {
        return (CPTYSpawnResult){ -1, -1, errno };
    }

    fcntl(master_fd, F_SETFD, FD_CLOEXEC);
    fcntl(slave_fd, F_SETFD, FD_CLOEXEC);

    int errpipe[2] = { -1, -1 };
    if (pipe(errpipe) == -1) {
        int saved = errno;
        cpty_close_if_valid(master_fd);
        cpty_close_if_valid(slave_fd);
        return (CPTYSpawnResult){ -1, -1, saved };
    }
    fcntl(errpipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(errpipe[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid == -1) {
        int saved = errno;
        cpty_close_if_valid(errpipe[0]);
        cpty_close_if_valid(errpipe[1]);
        cpty_close_if_valid(master_fd);
        cpty_close_if_valid(slave_fd);
        return (CPTYSpawnResult){ -1, -1, saved };
    }

    if (pid == 0) {
        /* Child: strictly async-signal-safe POSIX calls only before execvp. */
        cpty_close_if_valid(errpipe[0]);

        if (errpipe[1] <= STDERR_FILENO) {
            int moved = fcntl(errpipe[1], F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
            if (moved >= 0) {
                close(errpipe[1]);
                errpipe[1] = moved;
            }
        }

        sigset_t empty_mask;
        sigemptyset(&empty_mask);
        sigprocmask(SIG_SETMASK, &empty_mask, NULL);

        struct sigaction sa;
        sa.sa_handler = SIG_DFL;
        sa.sa_flags = 0;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGPIPE, &sa, NULL);

        if (setsid() == -1) {
            cpty_child_fail(errpipe[1], EIO);
        }

        if (ioctl(slave_fd, TIOCSCTTY, 0) == -1) {
            cpty_child_fail(errpipe[1], EIO);
        }

        if (dup2(slave_fd, STDIN_FILENO) == -1 ||
            dup2(slave_fd, STDOUT_FILENO) == -1 ||
            dup2(slave_fd, STDERR_FILENO) == -1) {
            cpty_child_fail(errpipe[1], EIO);
        }

        fcntl(STDIN_FILENO, F_SETFD, 0);
        fcntl(STDOUT_FILENO, F_SETFD, 0);
        fcntl(STDERR_FILENO, F_SETFD, 0);

        if (master_fd > STDERR_FILENO) {
            close(master_fd);
        }
        if (slave_fd > STDERR_FILENO) {
            close(slave_fd);
        }

        execvp(executable, argv);
        cpty_child_fail(errpipe[1], ENOENT);
    }

    /* Parent */
    cpty_close_if_valid(slave_fd);
    cpty_close_if_valid(errpipe[1]);

    int child_err = 0;
    ssize_t total = 0;
    while (total < (ssize_t)sizeof(child_err)) {
        ssize_t n = read(
            errpipe[0],
            ((char *)&child_err) + total,
            sizeof(child_err) - (size_t)total
        );
        if (n > 0) {
            total += n;
        } else if (n == 0) {
            break;
        } else if (errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    cpty_close_if_valid(errpipe[0]);

    if (total == (ssize_t)sizeof(child_err) && child_err != 0) {
        int status = 0;
        while (waitpid(pid, &status, 0) == -1 && errno == EINTR) {
        }
        cpty_close_if_valid(master_fd);
        return (CPTYSpawnResult){ -1, -1, child_err };
    }

    return (CPTYSpawnResult){ pid, master_fd, 0 };
}

int cpty_wait_no_reap(pid_t pid) {
    siginfo_t info;
    while (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT) == -1) {
        if (errno == EINTR) {
            continue;
        }
        return -1;
    }
    return 0;
}

int cpty_reap_exit_status(pid_t pid, int *out_exit_code) {
    int status = 0;
    while (waitpid(pid, &status, 0) == -1) {
        if (errno == EINTR) {
            continue;
        }
        if (out_exit_code != NULL) {
            *out_exit_code = -1;
        }
        return -1;
    }

    if (out_exit_code != NULL) {
        if (WIFEXITED(status)) {
            *out_exit_code = WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            *out_exit_code = 128 + WTERMSIG(status);
        } else {
            *out_exit_code = -1;
        }
    }
    return 0;
}
