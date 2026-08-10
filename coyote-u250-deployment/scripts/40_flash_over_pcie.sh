#!/usr/bin/env bash
#
# 40_flash_over_pcie.sh -- Write a Coyote image into the U250's QSPI flash over PCIe.
#
# THIS IS THE HIGHEST-RISK STEP IN THE DEPLOYMENT. Read the safety notes.
#
# SAFETY MODEL
#   1. The image is written to the *user* partition at 0x01002000. The factory
#      golden image at 0x0 is never touched.
#   2. Because the MCS start address is non-zero, xbflash2 installs a "bitstream
#      guard" before writing and removes it only after a successful write. An
#      interrupted flash therefore leaves the guard in place and the FPGA falls
#      back to the golden image on the next cold boot.
#   3. `xbflash2 program --spi --revert-to-golden` restores the factory state.
#
# The new image only takes effect after a COLD boot (full power cycle).
# A warm `reboot` does not re-read the flash.
#
# Usage:
#   sudo ./40_flash_over_pcie.sh --mcs-stem <path/stem> [--device BDF] [--yes]
#
#   --mcs-stem PATH  Stem such that PATH_primary.mcs and PATH_secondary.mcs exist.
#   --device BDF     PCI address, e.g. 0000:1a:00.0. Autodetected if omitted.
#   --xbflash2 PATH  Path to the xbflash2 binary (default: ./build/xbflash2).
#   --yesSkip the interactive confirmation.
#   --revert-to-golden   Restore the factory image instead of flashing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MCS_STEM=""
DEVICE=""
XBFLASH="$SCRIPT_DIR/build/xbflash2"
ASSUME_YES=0
REVERT=0

while (( $# )); do
    case "$1" in
        --mcs-stem)
            [[ $# -ge 2 ]] || { echo "error: --mcs-stem needs a value" >&2; exit 1; }
            MCS_STEM=$2; shift 2 ;;
        --device)
            [[ $# -ge 2 ]] || { echo "error: --device needs a value" >&2; exit 1; }
            DEVICE=$2; shift 2 ;;
        --xbflash2)
            [[ $# -ge 2 ]] || { echo "error: --xbflash2 needs a value" >&2; exit 1; }
            XBFLASH=$2; shift 2 ;;
        --yes) ASSUME_YES=1; shift ;;
        --revert-to-golden) REVERT=1; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

if (( EUID != 0 )); then
    echo "error: must run as root (BAR access via sysfs)" >&2
    exit 1
fi

if [[ ! -x "$XBFLASH" ]]; then
    echo "error: xbflash2 not found or not executable: $XBFLASH" >&2
    echo "       Build it first with 20_build_xbflash2.sh" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the target device
# ---------------------------------------------------------------------------
if [[ -z "$DEVICE" ]]; then
    mapfile -t CANDIDATES < <(lspci -Dn -d 10ee:2>/dev/null | awk '{print $1}')
    case ${#CANDIDATES[@]} in
        0) echo "error: no Xilinx (10ee) device found" >&2; exit 1 ;;
        1) DEVICE=${CANDIDATES[0]} ;;
        *) echo "error: multiple Xilinx devices; pass --device explicitly:" >&2
           printf '  %s\n' "${CANDIDATES[@]}" >&2; exit 1 ;;
    esac
fi

if [[ ! "$DEVICE" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
    echo "error: '$DEVICE' is not a valid BDF (expected form 0000:1a:00.0)" >&2
    exit 1
fi

DEVDIR="/sys/bus/pci/devices/$DEVICE"
[[ -d "$DEVDIR" ]] || { echo "error: no such PCI device: $DEVICE" >&2; exit 1; }

DEVID=$(cat "$DEVDIR/device")
echo "== Target =="
echo "  BDF       : $DEVICE"
echo "  device id : $DEVID"

case "${DEVID,,}" in
    0xd004) echo "  state: U250 factory golden image" ;;
    0x903f) echo "  state     : Coyote bitstream currently loaded" ;;
    *)      echo "  state     : unrecognised image" ;;
esac

# The Coyote driver must not hold the device while we touch the flash.
if lsmod | grep -q '^coyote_driver'; then
    echo
    echo "Removing coyote_driver so the DMA engine shuts down cleanly..."
    rmmod coyote_driver
fi
for mod in xocl xclmgmt ami; do
    if lsmod | grep -q "^$mod"; then
        echo "Removing conflicting module: $mod"
        rmmod "$mod" || true
    fi
done

# xbflash2 mmaps BAR0, which requires memory decoding to be enabled.
if [[ "$(cat "$DEVDIR/enable" 2>/dev/null || echo 0)" == "0" ]]; then
    echo "Enabling memory decoding for $DEVICE"
    echo 1 > "$DEVDIR/enable"
fi

# ---------------------------------------------------------------------------
# Revert path
# ---------------------------------------------------------------------------
if (( REVERT )); then
    echo
    echo "== Reverting to the factory golden image =="
    if (( ! ASSUME_YES )); then
        read -r -p "Proceed? [yes/NO] " reply
        [[ "$reply" == "yes" ]] || { echo "Aborted."; exit 1; }
    fi
    "$XBFLASH" program --spi --device "$DEVICE" --dual-flash --revert-to-golden
    echo
    echo "Done. COLD BOOT the machine for this to take effect."
    exit 0
fi

# ---------------------------------------------------------------------------
# Validate the MCS pair
# ---------------------------------------------------------------------------
if [[ -z "$MCS_STEM" ]]; then
    echo "error: --mcs-stem is required (or use --revert-to-golden)" >&2
    exit 1
fi

PRIMARY="${MCS_STEM}_primary.mcs"
SECONDARY="${MCS_STEM}_secondary.mcs"

for f in "$PRIMARY" "$SECONDARY"; do
    [[ -f "$f" ]] || { echo "error: missing MCS file: $f" >&2; exit 1; }
done

echo
echo "== Images =="
printf '  primary   : %s (%s bytes)\n' "$PRIMARY"   "$(stat -c%s "$PRIMARY")"
printf '  secondary : %s (%s bytes)\n' "$SECONDARY" "$(stat -c%s "$SECONDARY")"

# The first data record's address decides whether xbflash2 arms the bitstream
# guard. Address 0 would mean overwriting the golden image -- refuse that.
FIRST_ADDR=$(grep -m1 -E '^:[0-9A-Fa-f]{2}' "$PRIMARY" | cut -c4-7|| true)
FIRST_REC=$(head -1 "$PRIMARY")
echo "  first record in primary: $FIRST_REC"

if [[ "$FIRST_REC" =~ ^:0[24] ]]; then
    echo "  (extended address record present -- image is not at offset 0, good)"
else
    echo
    echo "WARNING: could not confirm a non-zero start address in $PRIMARY."
    echo "         If this image starts at 0x0 it would overwrite the GOLDEN"
    echo "         image and remove your recovery path."
    if (( ! ASSUME_YES )); then
        read -r -p "         Continue anyway? [yes/NO] " reply
        [[ "$reply" == "yes" ]] || { echo "Aborted."; exit 1; }
    fi
fi

# ---------------------------------------------------------------------------
# Confirm and flash
# ---------------------------------------------------------------------------
cat <<EOF

== About to write flash ==
  device: $DEVICE
  destination : user partition at 0x01002000
  golden image: NOT modified (recovery remains available)

  Do not power off or interrupt this process. It can take several minutes.
EOF

if (( ! ASSUME_YES )); then
    read -r -p "Type 'yes' to proceed: " reply
    [[ "$reply" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

echo
echo "== Flashing =="
set +e
"$XBFLASH" program --spi \
    --device "$DEVICE" \
    --dual-flash \
    --image "$PRIMARY" \
    --image "$SECONDARY"
RC=$?
set -e

echo
if (( RC != 0 )); then
    cat <<EOF
== FLASH FAILED (exit $RC) ==

The bitstream guard should still be armed, so the card will boot the golden
image after a cold reboot. Recovery options:

  1. Retry this script.
  2. Restore the factory image:
       sudo $0 --revert-to-golden --device $DEVICE
EOF
    exit "$RC"
fi

cat <<EOF
== FLASH SUCCEEDED ==

The image is written but NOT yet active. The FPGA only reads flash at power-on,
so you must COLD BOOT the machine. A warm 'reboot' is not sufficient.

  Remote cold boot via BMC:
    sudo ipmitool chassis power cycle

  Then verify the card came up as Coyote (expect device id 0x903f):
    lspci -Dn -d 10ee:

  If the id is still 0xd004, the FPGA fell back to golden. See
  docs 99-troubleshooting.md.
EOF
