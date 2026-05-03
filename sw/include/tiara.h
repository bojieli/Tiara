// Tiara client API.
//
// A real deployment connects to the memory-side NIC over RDMA reliable
// connection (RC) and ships:
//     [ operator_id : 32 ][ task_id : 32 ][ args[0..7] : 8x8 bytes ]
//
// The NIC's task dispatcher matches `operator_id` against the
// previously registered binaries, allocates a free memory processor,
// loads r1..r8 with the args, and runs the operator.  The result is
// returned in a single response carrying `r1..r4`.
//
// In simulation mode (TIARA_SIM=1) the client talks to the Verilator
// simulator binary via the protocol implemented in `client.c`.

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Public type so users can construct addresses without depending on
   the verifier's ABI. */
typedef struct {
    uint16_t device;
    uint16_t region;
    uint32_t offset;
} tiara_addr_t;

static inline uint64_t tiara_addr_pack(tiara_addr_t a) {
    return ((uint64_t)a.device << 48) |
           ((uint64_t)a.region << 32) |
           (uint64_t)a.offset;
}

static inline tiara_addr_t tiara_addr_local(uint16_t region, uint32_t offset) {
    tiara_addr_t a = {0, region, offset};
    return a;
}

typedef struct tiara_client tiara_client_t;

/* Connect to a memory-side NIC.  In simulation mode `endpoint` is the
   path to the simulator binary; in deployment mode it is the
   `host:port` of the NIC's control plane. */
tiara_client_t* tiara_connect(const char* endpoint);
void            tiara_close  (tiara_client_t* c);

/* Register an assembled operator binary.  Returns the operator id on
   success, -1 on failure. */
int32_t tiara_register_operator(tiara_client_t* c,
                                 const char*    binary_path,
                                 const char*    manifest_path);

/* Invoke a previously registered operator.  Returns 0 on success.
   `result[0..3]` is filled with r1..r4. */
int tiara_invoke(tiara_client_t* c,
                 int32_t         operator_id,
                 const uint64_t  args[8],
                 uint64_t        result[4]);

#ifdef __cplusplus
}
#endif
