# Tiara top-level Makefile.

PY ?= python3

.PHONY: all sim selftest test eval bench client clean help docs synth impl

VIVADO ?= vivado

help:
	@echo "Tiara top-level targets:"
	@echo "  make sim         - build the Verilator-based cycle-accurate simulator"
	@echo "  make selftest    - run the simulator self-test"
	@echo "  make test        - run unit tests (assembler, verifier, RTL)"
	@echo "  make eval        - run the four paper workloads, drop CSVs in eval/results"
	@echo "  make bench       - run a quick smoke benchmark (graph @ depth 1..3)"
	@echo "  make client      - build the C client library"
	@echo "  make docs        - regenerate auto-generated docs (ISA package)"
	@echo "  make synth       - Vivado OOC synth on Alveo U50 (Tiara core)"
	@echo "  make impl        - Vivado place + route + timing + util reports"
	@echo "  make synth_app   - Vivado OOC synth on Tiara + Corundum app block"
	@echo "  make bitstream   - Build full U50 + Corundum + Tiara bitstream"
	@echo "  make program     - Program U50 over JTAG with built bitstream"
	@echo "  make clean       - remove build outputs"

all: sim client

sim: rtl/include/tiara_pkg.svh
	$(MAKE) -C sim/verilator

rtl/include/tiara_pkg.svh: scripts/gen_isa_pkg.py sw/asm/tiara_isa.py
	$(PY) scripts/gen_isa_pkg.py

selftest: sim
	sim/verilator/build/Vtiara_nic_top --selftest

test: sim
	$(PY) -m unittest discover -s sw/tests -p '*_test.py' -v

eval: sim
	mkdir -p eval/results eval/figures
	$(PY) eval/scripts/harness.py graph  --max-depth 10 \
	    --out eval/results/graph_traversal.dat
	$(PY) eval/scripts/harness.py ptwalk \
	    --out eval/results/pt_walk.dat
	$(PY) eval/scripts/harness.py paged \
	    --block-sizes 1024 4096 8192 16384 65536 262144 \
	    --out eval/results/paged_attention.dat
	$(PY) eval/scripts/plots.py

bench: sim
	$(PY) eval/scripts/harness.py graph --max-depth 3

client: sw/include/tiara.h
	$(MAKE) -C sw/client

docs: rtl/include/tiara_pkg.svh

synth: rtl/include/tiara_pkg.svh
	$(VIVADO) -mode batch -source tcl/synth.tcl -log synth/vivado_synth.log -journal synth/vivado_synth.jou
	@echo "==== Post-synth utilization (head) ===="
	@head -80 synth/util_post_synth.rpt || true
	@echo "==== Post-synth WNS ===="
	@grep -E '^\s*WNS|^\s*Slack' synth/timing_post_synth.rpt | head -5 || true

impl: synth
	$(VIVADO) -mode batch -source tcl/impl.tcl -log synth/vivado_impl.log -journal synth/vivado_impl.jou
	@echo "==== Post-route utilization (head) ===="
	@head -80 synth/util_post_route.rpt || true
	@echo "==== Post-route timing summary ===="
	@grep -E '^\s*WNS|^\s*Slack|^\s*WHS|^\s*TNS' synth/timing_post_route.rpt | head -10 || true

synth_app: rtl/include/tiara_pkg.svh vendor/corundum
	$(VIVADO) -mode batch -source tcl/synth_app.tcl -log synth_app/vivado.log -journal synth_app/vivado.jou
	@echo "==== Post-synth utilization (Tiara + Corundum app) ===="
	@head -65 synth_app/util_post_synth.rpt | tail -15 || true
	@grep -A 4 'WNS(ns)' synth_app/timing_post_synth.rpt | head -6 || true

vendor/corundum:
	git clone --depth 1 https://github.com/corundum/corundum vendor/corundum

bitstream: rtl/include/tiara_pkg.svh vendor/corundum
	bash scripts/build_bitstream.sh

program:
	$(VIVADO) -mode batch -source tcl/program.tcl -nojournal -nolog

clean:
	$(MAKE) -C sim/verilator clean
	$(MAKE) -C sw/client clean
	rm -rf eval/results eval/figures synth
	find sw/operators -name '*.bin' -delete
