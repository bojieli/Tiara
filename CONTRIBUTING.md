# Contributing to Tiara

## Development setup

1. `apt-get install verilator iverilog python3-numpy python3-matplotlib build-essential`
2. `make docs && make sim && make test` should pass before sending a PR.

## Style

- **RTL**: SystemVerilog ’12, snake_case modules, `tiara_` prefix on
  every module name, one module per file.
- **Python**: PEP 8, type hints on public APIs.
- **C**: C11, no warnings under `-Wall -Wextra -Werror`.
- Keep the auto-generated `rtl/include/tiara_pkg.svh` in sync with
  `sw/asm/tiara_isa.py` by running `make docs`. CI fails if they diverge.

## Adding a new operator

1. Write `sw/operators/<name>.tasm`. Read `docs/ISA.md` for the ISA.
2. Write `sw/operators/<name>.toml` declaring arguments + regions.
3. `python3 sw/verifier/tiara_verifier.py <name>.tasm <name>.toml` —
   must pass.
4. Add a unit test in `sw/tests/sim_test.py`.
5. (Optional) wire it into `eval/scripts/harness.py` if you want it
   in `make eval`.

## Adding a new ISA opcode

1. Add to `Op` (and possibly `Sub`) in `sw/asm/tiara_isa.py`.
2. Run `make docs` to regenerate `rtl/include/tiara_pkg.svh`.
3. Wire the opcode into the MP's `S_EXECUTE` decode (and possibly
   `S_MEM_WAIT`) in `rtl/tiara_nic/tiara_mp.sv`.
4. Add the verifier semantics in `sw/verifier/tiara_verifier.py`.
5. Add an `IsaTest` round-trip and a `SimTest` end-to-end case.

## Adding a new memory engine

The memory subsystem (`tiara_memory_subsystem.sv`) routes by device
ID. To plug in a new engine (e.g. CXL): add it to the subsystem's
mux, and update `dev_of(addr)` to discriminate on a new ID range.

## Releasing

We follow semantic versioning. The "breaking change" surface is:

- The Tiara ISA encoding (`docs/ISA.md`).
- The host loader package format.
- The C client ABI in `sw/include/tiara.h`.

Breaking these requires a major version bump.
