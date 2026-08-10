#!/usr/bin/env bash
#
# 20_build_xbflash2.sh -- Build the standalone xbflash2 flash utility from XRT sources.
#
# Why this exists
# ---------------
# xbflash2 writes a bitstream image into the Alveo card's on-board QSPI flash
# *over PCIe*. That removes the need for a JTAG cable, which is otherwise
# mandatory for the first Coyote bring-up.
#
# Per AMD's own documentation (XRT docs, xbflash2.rst):
#   "a standalone command line utility to flash a custom image onto given device"
#   "This tool doesn't require XRT Package"
#   "This tool is verified and supported only on XDMA PCIe DMA designs"
#
# Coyote is an XDMA design, so this is a supported configuration.
#
# The tool reaches the card's AXI Quad SPI controller by mmap'ing BAR0 through
# sysfs, so neither the xocl/xclmgmt kernel modules nor the XRT runtime are
# needed -- we only compile this one binary out of the XRT source tree.
#
# Usage: ./20_build_xbflash2.sh --xrt-src /path/to/XRT/src [--out DIR]
#
#   --xrt-src DIR   Path to the 'src' directory of an XRT checkout (required).
#   --out DIR       Where to place the binary (default: ./build).

set -euo pipefail

XRT_SRC=""
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build"

while (( $# )); do
    case "$1" in
        --xrt-src)
            [[ $# -ge 2 ]] || { echo "error: --xrt-src needs a value" >&2; exit 1; }
            XRT_SRC=$2; shift 2 ;;
        --out)
            [[ $# -ge 2 ]] || { echo "error: --out needs a value" >&2; exit 1; }
            OUT_DIR=$2; shift 2 ;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0 ;;
        *)
            echo "error: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

if [[ -z "$XRT_SRC" ]]; then
    echo "error: --xrt-src is required" >&2
    echo "       Get XRT with: git clone https://github.com/Xilinx/XRT.git" >&2
    echo "       Then pass the 'src' subdirectory." >&2
    exit 1
fi

XRT_SRC=$(cd "$XRT_SRC" && pwd)

TOOLS="$XRT_SRC/runtime_src/core/tools"
QSPI="$XRT_SRC/runtime_src/core/pcie/tools/xbflash.qspi"
CFG="$XRT_SRC/CMake/config"

for d in "$TOOLS/xbflash2" "$TOOLS/common" "$QSPI" "$CFG"; do
    [[ -d "$d" ]] || { echo "error: expected directory not found: $d" >&2; exit 1; }
done

GEN="$OUT_DIR/gen"
mkdir -p "$GEN/xrt/detail" "$OUT_DIR"

echo "== Generating version headers =="
# XRT normally generates these from git metadata via CMake. We are building a
# single tool outside that flow, so substitute placeholder values.
subst_version() {
    sed \
        -e 's|@XRT_VERSION_STRING@|0.0.0|g' \
        -e 's|@XRT_VERSION_MAJOR@|0|g' \
        -e 's|@XRT_VERSION_MINOR@|0|g' \
        -e 's|@XRT_VERSION_PATCH@|0|g' \
        -e 's|@XRT_HEAD_COMMITS@|0|g' \
        -e 's|@XRT_BRANCH_COMMITS@|0|g' \
        -e 's|@XRT_HASH@|0000000000000000000000000000000000000000|g' \
        -e 's|@XRT_HASH_DATE@|na|g' \
        -e 's|@XRT_BRANCH@|standalone|g' \
        -e 's|@XRT_MODIFIED_FILES@||g' \
        -e 's|@XRT_DATE_RFC@|na|g' \
        -e 's|@XRT_DATE@|na|g' \
        "$1" > "$2"
}
subst_version "$CFG/version.h.in"      "$GEN/version.h"
subst_version "$CFG/version-slim.h.in" "$GEN/xrt/detail/version-slim.h"
subst_version "$CFG/version-git.h.in"  "$GEN/xrt/detail/version-git.h"

# Source list mirrors src/runtime_src/core/tools/xbflash2/CMakeLists.txt
SOURCES=(
    "$TOOLS/common/XBUtilitiesCore.cpp"
    "$TOOLS/common/SubCmd.cpp"
    "$TOOLS/common/OptionOptions.cpp"
    "$TOOLS/common/XBHelpMenusCore.cpp"
    "$TOOLS/common/JSONConfigurable.cpp"
    "$QSPI/firmware_image.cpp"
    "$QSPI/pcidev.cpp"
    "$QSPI/xqspips.cpp"
    "$QSPI/xspi.cpp"
)
while IFS= read -r f; do SOURCES+=("$f"); done \
    < <(find "$TOOLS/xbflash2" -maxdepth 1 -name '*.cpp' | sort)

echo "== Compiling xbflash2 (${#SOURCES[@]} translation units) =="
g++ -std=c++17 -O2 -o "$OUT_DIR/xbflash2" \
    "${SOURCES[@]}" \
    -I"$GEN" \
    -I"$XRT_SRC" \
    -I"$XRT_SRC/include" \
    -I"$XRT_SRC/runtime_src" \
    -I"$XRT_SRC/runtime_src/core" \
    -I"$XRT_SRC/runtime_src/core/include" \
    -I"$TOOLS/xbflash2" \
    -I"$TOOLS/common" \
    -I"$QSPI" \
    -lboost_program_options -lboost_filesystem -lboost_system -lpthread -luuid

echo
echo "== Done =="
ls -l "$OUT_DIR/xbflash2"
echo
echo "Sanity check:"
"$OUT_DIR/xbflash2" --help 2>&1 | head -12 || true
