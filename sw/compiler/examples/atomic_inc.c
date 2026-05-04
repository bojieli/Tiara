// atomic_inc.c — fetch-and-add (CAA) at a fixed offset in region 0.
//
// Args:
//   r1 = base address (in region 0).
//   r2 = increment.
// Returns:
//   r1 = old value.

typedef unsigned long uint64_t;

uint64_t atomic_inc(uint64_t base_in_counters_0x10000,
                    uint64_t delta) {
    uint64_t old = tiara_caa(base_in_counters_0x10000, delta);
    return old;
}
