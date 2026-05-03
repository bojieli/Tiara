// Tiara client — simulation-mode reference implementation.
//
// Spawns the Verilator simulator binary on each invocation and parses
// its `RESULT cycles=... r0=... r1=... r2=... r3=...` line.  This is
// good enough for benchmarking against the analytical baselines in
// `eval/scripts/baselines.py`.  The deployment version (talking to the
// memory-side NIC over RDMA) lives in `client_rdma.c` (TODO).

#define _POSIX_C_SOURCE 200809L

#include "tiara.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

struct tiara_client {
    char*  sim_binary;        // path to the Verilator binary
    int    n_operators;
    char** operator_paths;    // operator_id -> binary path
};

tiara_client_t* tiara_connect(const char* endpoint) {
    tiara_client_t* c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->sim_binary = strdup(endpoint);
    return c;
}

void tiara_close(tiara_client_t* c) {
    if (!c) return;
    free(c->sim_binary);
    for (int i = 0; i < c->n_operators; i++) free(c->operator_paths[i]);
    free(c->operator_paths);
    free(c);
}

int32_t tiara_register_operator(tiara_client_t* c,
                                const char*    binary_path,
                                const char*    manifest_path) {
    (void)manifest_path;  // verification is done out-of-band by `tiara_verifier.py`
    if (!c || !binary_path) return -1;
    char** g = realloc(c->operator_paths,
                       sizeof(char*) * (c->n_operators + 1));
    if (!g) return -1;
    c->operator_paths = g;
    c->operator_paths[c->n_operators] = strdup(binary_path);
    return c->n_operators++;
}

int tiara_invoke(tiara_client_t* c,
                 int32_t         operator_id,
                 const uint64_t  args[8],
                 uint64_t        result[4]) {
    if (!c || operator_id < 0 || operator_id >= c->n_operators) return -1;
    char arg_buf[256];
    int n = snprintf(arg_buf, sizeof(arg_buf),
                     "%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu",
                     (unsigned long long)args[0],
                     (unsigned long long)args[1],
                     (unsigned long long)args[2],
                     (unsigned long long)args[3],
                     (unsigned long long)args[4],
                     (unsigned long long)args[5],
                     (unsigned long long)args[6],
                     (unsigned long long)args[7]);
    if (n <= 0 || (size_t)n >= sizeof(arg_buf)) return -1;

    int pipefd[2];
    if (pipe(pipefd) < 0) return -1;

    pid_t pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); return -1; }
    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], 1);
        close(pipefd[1]);
        execl(c->sim_binary, c->sim_binary,
              "--op", c->operator_paths[operator_id],
              "--args", arg_buf,
              (char*)NULL);
        _exit(127);
    }
    close(pipefd[1]);
    char buf[1024];
    ssize_t got = 0, n_read;
    while ((n_read = read(pipefd[0], buf + got,
                          sizeof(buf) - 1 - got)) > 0) {
        got += n_read;
    }
    close(pipefd[0]);
    int status;
    waitpid(pid, &status, 0);
    buf[got] = 0;

    char* line = strstr(buf, "RESULT ");
    if (!line) return -1;
    unsigned long long cycles, r[4];
    int err, retired;
    int matched = sscanf(line,
        "RESULT cycles=%llu err=%d instr_retired=%d "
        "r0=%llx r1=%llx r2=%llx r3=%llx",
        &cycles, &err, &retired, &r[0], &r[1], &r[2], &r[3]);
    if (matched != 7) return -1;
    for (int i = 0; i < 4; i++) result[i] = r[i];
    return err ? 1 : 0;
}
