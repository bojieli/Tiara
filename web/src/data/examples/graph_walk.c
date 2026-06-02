// graph_walk.c — Tiara-C source for the depth-limited pointer chase.
//
// Args (mapped to r1..r2 in declaration order):
//   - cur:   current node address (region 0, "graph_pool")
//   - depth: number of hops to chase
//
// Returns r1 = data field of final node visited.
//
// The pointer arg `cur_in_graph_pool_0x80000000` triggers the
// compiler's region naming convention: the suffix after `_in_` is
// "<region_name>_<size>".  The verifier sees `region graph_pool 0`.
//
// `tiara_andi` is required after every LOAD whose result becomes an
// address — paper §3.3 / verifier mandate.

// Args:
//   cur_in_graph_pool_0x80000000 : pointer into "graph_pool" region (size = 2 GiB).
//   depth                        : hop count (bounded by the verifier).

uint64_t graph_walk(uint64_t* cur_in_graph_pool_0x80000000,
                    uint64_t  depth) {
    for (int i = 0; i < depth; i++) {
        uint64_t nxt = cur_in_graph_pool_0x80000000[1];
        // Re-cast the pointer through tiara_andi so the verifier
        // recognizes the masked LOAD result as an in-region offset.
        uint64_t cur_off = tiara_andi(nxt, 0x7FFFFFF8);
        cur_in_graph_pool_0x80000000 = (uint64_t*)cur_off;
    }
    uint64_t data = cur_in_graph_pool_0x80000000[0];
    tiara_set_result(2, (uint64_t)cur_in_graph_pool_0x80000000);
    return data;
}
