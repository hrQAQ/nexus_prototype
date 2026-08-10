#!/usr/bin/env bash
#
# 50_load_driver.sh -- Insert the Coyote driver and verify the card came up.
#
# Run this after a cold boot, once `lspci -d 10ee:` reports device id 0x903f.
#
# Usage:
#   sudo ./50_load_driver.sh --driver /path/to/coyote_driver.ko [options]
#
#   --driver PATH   Path to coyote_driver.ko (required).
#   --ip HEX        FPGA IP address in hex, for networked builds only.
#   --mac HEX       FPGA MAC address in hex, for networked builds only.
#   --reload        Remove an already-loaded coyote_driver first.

set -euo pipefail

DRIVER=""
IP_HEX=""
MAC_HEX=""
RELOAD=0

while (( $# )); do
    case "$1" in
        --driver)
            [[ $# -ge 2 ]] || { echo "error: --driver needs a value" >&2; exit 1; }
            DRIVER=$2; shift 2 ;;
        --ip)
            [[ $# -ge 2 ]] || { echo "error: --ip needs a value" >&2; exit 1; }
            IP_HEX=$2; shift 2 ;;
        --mac)
            [[ $# -ge 2 ]] || { echo "error: --mac needs a value" >&2; exit 1; }
            MAC_HEX=$2; shift 2 ;;
        --reload) RELOAD=1; shift ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

if (( EUID != 0 )); then
    echo "error: must run as root" >&2
    exit 1
fi

if [[ -z "$DRIVER" ]]; then
    echo "error: --driver is required" >&2
    exit 1
fi
if [[ ! -f "$DRIVER" ]]; then
    echo "error: no such file: $DRIVER" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Precondition: the card must be running a Coyote bitstream.
# ---------------------------------------------------------------------------
echo "== Checking the card =="
mapfile -t DEVS < <(lspci -Dn -d 10ee: 2>/dev/null | awk '{print $1}')
if (( ${#DEVS[@]} == 0 )); then
    echo "error: no Xilinx device on the bus." >&2
    echo "       If you just flashed and cold-booted, the FPGA may have failed to" >&2
    echo "       configure. See 99-troubleshooting.md." >&2
    exit 1
fi

FOUND_COYOTE=0
for bdf in "${DEVS[@]}"; do
    did=$(cat "/sys/bus/pci/devices/$bdf/device")
    echo "  $bdf -> $did"
    case "${did,,}" in
        0x903f) FOUND_COYOTE=1 ;;
        0xd004)
            echo
            echo "error: $bdf still reports 0xd004 (factory golden image)." >&2
            echo "       The Coyote image is not active. Either the flash write did" >&2
            echo "       not take, or the FPGA fell back to golden." >&2
            exit 1 ;;
    esac
done

if (( ! FOUND_COYOTE )); then
    echo
    echo "error: no device with the Coyote XDMA id 0x903f was found." >&2
    exit 1
fi
echo "  Coyote bitstream detected (0x903f)."

# ---------------------------------------------------------------------------
# Preconditions on the host
# ---------------------------------------------------------------------------
HP=$(awk '/^HugePages_Total:/ {print $2}' /proc/meminfo)
if [[ "${HP:-0}" -lt 1 ]]; then
    echo
    echo "error: no hugepages reserved. Run 10_setup_host.sh." >&2
    exit 1
fi
echo "  hugepages: $HP"

if lsmod | grep -q '^coyote_driver'; then
    if (( RELOAD )); then
        echo "  removing the existing coyote_driver"
        rmmod coyote_driver
    else
        echo
        echo "error: coyote_driver is already loaded. Use --reload to replace it." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Insert
# ---------------------------------------------------------------------------
echo
echo "== Inserting the driver =="
echo "  $DRIVER"

INSMOD_ARGS=()
if [[ -n "$IP_HEX" ]]; then
    [[ "$IP_HEX" =~ ^(0x)?[0-9a-fA-F]+$ ]] || { echo "error: --ip must be hex" >&2; exit 1; }
    INSMOD_ARGS+=("ip_addr=$IP_HEX")
fi
if [[ -n "$MAC_HEX" ]]; then
    [[ "$MAC_HEX" =~ ^(0x)?[0-9a-fA-F]+$ ]] || { echo "error: --mac must be hex" >&2; exit 1; }
    INSMOD_ARGS+=("mac_addr=$MAC_HEX")
fi

DMESG_MARK=$(dmesg | wc -l)

if (( ${#INSMOD_ARGS[@]} )); then
    echo "  parameters: ${INSMOD_ARGS[*]}"
    insmod "$DRIVER" "${INSMOD_ARGS[@]}"
else
    insmod "$DRIVER"
fi

sleep 1

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo
echo "== Kernel log since insmod =="
dmesg | tail -n +"$((DMESG_MARK + 1))" | sed 's/^/  /'

echo
echo "== Character devices =="
ls -l /dev/fpga* 2>/dev/null | sed 's/^/  /' || echo "  none found"

echo
if dmesg | tail -40 | grep -q "probe returning 0"; then
    echo "SUCCESS: 'probe returning 0' found. The driver bound to the card."
    echo
    echo "Next: run the Coyote example, e.g."
    echo "  cd Coyote/examples/01_hello_world/sw/build_sw && ./test"
    exit 0
fi

echo "WARNING: did not see 'probe returning 0' in the kernel log."
echo "         Inspect the full log with: dmesg | tail -60"
echo "         See 99-troubleshooting.md."
exit 1
