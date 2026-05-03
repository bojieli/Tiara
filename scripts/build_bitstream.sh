#!/usr/bin/env bash
# Drive the full U50 + Corundum + Tiara bitstream build.
#
#   ./scripts/build_bitstream.sh
#
# Requires Vivado ML Standard 2025.2+ on PATH.

set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

CORUNDUM=$ROOT/vendor/corundum
APP_DST=$CORUNDUM/fpga/mqnic/Alveo/fpga_25g/app/template/rtl
APP_SRC=$ROOT/integration/corundum_app/rtl
TIARA_RTL=$ROOT/rtl/tiara_nic
TIARA_INC=$ROOT/rtl/include
AU50_DIR=$CORUNDUM/fpga/mqnic/Alveo/fpga_25g/fpga_AU50
BUILD_DIR=$ROOT/hw/build

[ -d "$CORUNDUM" ] || { echo "missing $CORUNDUM — run: git submodule update --init"; exit 1; }
which vivado >/dev/null 2>&1 || { echo "vivado not on PATH — source settings64.sh"; exit 1; }

# 1) sanity-check the Tiara core elaborates standalone
echo "=== [1/4] Tiara core OOC sanity check ==="
make -C "$ROOT" docs >/dev/null   # regenerate tiara_pkg.svh
vivado -mode batch -source tcl/synth.tcl -log /tmp/tiara_synth.log -journal /tmp/tiara_synth.jou \
    | grep -E 'TIARA-SYNTH-DONE|ERROR' || true

# 2) Splice our mqnic_app_block into Corundum's template tree
echo "=== [2/4] Splicing Tiara app block into Corundum ==="
cp -v "$APP_SRC/mqnic_app_block.sv" "$APP_DST/"
# Remove the original Corundum template's .v if present so Vivado does
# not pick up two definitions of the same module.
rm -f "$APP_DST/mqnic_app_block.v"
mkdir -p "$APP_DST/tiara"
cp -rv "$TIARA_RTL"/*.sv          "$APP_DST/tiara/"
cp -v  "$TIARA_INC/tiara_pkg.svh" "$APP_DST/tiara/"
cp -v  "$APP_SRC/tiara_axil_slave.sv" "$APP_DST/tiara/"
cp -v  "$APP_SRC/tiara_packet.svh"    "$APP_DST/tiara/"
cp -v  "$APP_SRC/tiara_rx_filter.sv"  "$APP_DST/tiara/"
cp -v  "$APP_SRC/tiara_tx_resp.sv"    "$APP_DST/tiara/"
cp -v  "$APP_SRC/tiara_tx_arb.sv"     "$APP_DST/tiara/"

# 3) Inject Tiara into Corundum's filelist + app-block module list +
#    enable APP_ENABLE in config.tcl
echo "=== [3/4] Patching AU50 Makefile + config.tcl for Tiara ==="
MK="$AU50_DIR/Makefile"
TIARA_BASE="../app/template/rtl/tiara"
TIARA_BASE="app/template/rtl/tiara"
if ! grep -q 'tiara_pkg.svh' "$MK"; then
    awk -v TB="$TIARA_BASE" '/^SYN_FILES \+= rtl\/sync_signal.v$/ {
        print
        print "SYN_FILES += app/template/rtl/mqnic_app_block.sv"
        print "SYN_FILES += " TB "/tiara_pkg.svh"
        print "SYN_FILES += " TB "/tiara_packet.svh"
        print "SYN_FILES += " TB "/tiara_mem_if.sv"
        print "SYN_FILES += " TB "/tiara_alu.sv"
        print "SYN_FILES += " TB "/tiara_regfile.sv"
        print "SYN_FILES += " TB "/tiara_istore.sv"
        print "SYN_FILES += " TB "/tiara_loop_stack.sv"
        print "SYN_FILES += " TB "/tiara_mp.sv"
        print "SYN_FILES += " TB "/tiara_dispatcher.sv"
        print "SYN_FILES += " TB "/tiara_mem_simple.sv"
        print "SYN_FILES += " TB "/tiara_synth_top.sv"
        print "SYN_FILES += " TB "/tiara_axil_slave.sv"
        print "SYN_FILES += " TB "/tiara_rx_filter.sv"
        print "SYN_FILES += " TB "/tiara_tx_resp.sv"
        print "SYN_FILES += " TB "/tiara_tx_arb.sv"
        next
    }
    { print }' "$MK" > "$MK.new" && mv "$MK.new" "$MK"
fi
# Enable the app block in config.tcl
sed -i 's/dict set params APP_ENABLE "0"/dict set params APP_ENABLE "1"/' \
    "$AU50_DIR/config.tcl"

# 4) Run Corundum's bitstream build
echo "=== [4/4] Running Corundum AU50 bitstream build ==="
mkdir -p "$BUILD_DIR"
( cd "$AU50_DIR" && make all )
cp "$AU50_DIR"/fpga.bit  "$BUILD_DIR/" 2>/dev/null || true
cp "$AU50_DIR"/fpga.mcs  "$BUILD_DIR/" 2>/dev/null || true
cp "$AU50_DIR"/fpga.prm  "$BUILD_DIR/" 2>/dev/null || true

echo "=== bitstream build complete ==="
ls -lh "$BUILD_DIR"/
