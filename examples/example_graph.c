// Tiny C example: register the graph_walk operator, build a 3-node
// graph in host DRAM, traverse it, and print the result.
//
//   make -C sw/client
//   gcc examples/example_graph.c -Isw/include -Lsw/client -ltiara \
//        -o build/example_graph
//   build/example_graph

#include "tiara.h"
#include <inttypes.h>
#include <stdio.h>

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <path-to-Vtiara_nic_top>\n", argv[0]);
        return 2;
    }
    tiara_client_t* c = tiara_connect(argv[1]);
    int32_t op = tiara_register_operator(c,
        "sw/operators/graph_walk.bin",
        "sw/operators/graph_walk.toml");
    if (op < 0) { fprintf(stderr, "registration failed\n"); return 1; }
    uint64_t args[8] = {0, 3, 0, 0, 0, 0, 0, 0};   // start at byte 0, depth 3
    uint64_t res[4] = {0};
    int rc = tiara_invoke(c, op, args, res);
    printf("rc=%d  data=%016" PRIx64 "  addr=%016" PRIx64 "\n",
           rc, res[0], res[1]);
    tiara_close(c);
    return rc;
}
