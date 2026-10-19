#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* This helper owns exactly one process group. It never enumerates processes,
 * uses names, or signals the caller's process group. Keep the child (the group
 * leader) unreaped until the final group signal so its PID cannot be reused. */
static volatile sig_atomic_t requested_signal = 0;

static void request_stop(int signal_number) {
    requested_signal = signal_number;
}

static double monotonic_time(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

int main(int argc, char **argv) {
    if (argc < 2 || argv[1][0] != '/') {
        fputs("ProcessLauncher requires an absolute executable path.\n", stderr);
        return 64;
    }

    const pid_t owner = getppid();
    sigset_t blocked, original_mask;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGTERM);
    sigaddset(&blocked, SIGINT);
    sigaddset(&blocked, SIGHUP);
    if (sigprocmask(SIG_BLOCK, &blocked, &original_mask) != 0) return 71;

    struct sigaction handler = {0};
    handler.sa_handler = request_stop;
    sigemptyset(&handler.sa_mask);
    sigaction(SIGTERM, &handler, NULL);
    sigaction(SIGINT, &handler, NULL);
    sigaction(SIGHUP, &handler, NULL);

    const pid_t child = fork();
    if (child < 0) {
        perror("ProcessLauncher fork");
        return 71;
    }
    if (child == 0) {
        if (setpgid(0, 0) != 0) _exit(71);
        handler.sa_handler = SIG_DFL;
        sigaction(SIGTERM, &handler, NULL);
        sigaction(SIGINT, &handler, NULL);
        sigaction(SIGHUP, &handler, NULL);
        sigprocmask(SIG_SETMASK, &original_mask, NULL);
        execv(argv[1], &argv[1]);
        perror("ProcessLauncher exec");
        _exit(127);
    }

    /* Both sides set the group, removing the signal-before-setpgid race. EACCES
     * means the child has already exec'd after setting its own process group. */
    if (setpgid(child, child) != 0 && errno != EACCES && errno != ESRCH) {
        kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        return 71;
    }
    sigprocmask(SIG_SETMASK, &original_mask, NULL);
    /* Only the command consumes input. Keeping this read end open would hide
     * EPIPE from the caller after the command closes stdin. */
    close(STDIN_FILENO);

    double stop_started = 0;
    for (;;) {
        siginfo_t information = {0};
        int observed = waitid(P_PID, (id_t)child, &information, WEXITED | WNOHANG | WNOWAIT);
        if (observed < 0 && errno != EINTR) {
            /* Unexpected loss of child ownership: do not signal a possibly
             * recycled group ID. Normal operation always owns an unreaped child. */
            return 71;
        }
        if (observed == 0 && information.si_pid == child) {
            /* The requested command is done. Any remaining processes in its
             * group are leftovers; do not leave inherited pipes open. */
            kill(-child, SIGTERM);
            kill(-child, SIGKILL);
            break;
        }
        if (requested_signal != 0 || getppid() != owner) {
            if (stop_started == 0) {
                stop_started = monotonic_time();
                kill(-child, requested_signal != 0 ? requested_signal : SIGTERM);
            } else if (monotonic_time() - stop_started >= 0.35) {
                kill(-child, SIGKILL);
                /* The direct child is still ours even if it changed its group. */
                kill(child, SIGKILL);
                break;
            }
        }
        struct timespec pause = {0, 10000000};
        nanosleep(&pause, NULL);
    }

    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return 71;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 71;
}
