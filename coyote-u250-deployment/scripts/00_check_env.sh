#!/usr/bin/env bash
#
# 00_check_env.sh -- Verify a host isready to deploy Coyote on an Alveo U250.
#
# Read-only. Makes no changes to the system. Run this first on any new machine.
#
# Usage: ./00_check_env.sh
#
# Exit code 0 means every mandatory check passed.

set -uo pipefail

PASS=0
FAIL=0
WARN=0

ok(){ printf '  [ OK ]   %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  [FAIL]   %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '  [WARN]   %s\n' "$*"; WARN=$((WARN + 1)); }
info() { printf '  [info]   %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }

head_ "Operating system"
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    info "Distribution: ${PRETTY_NAME:-unknown}"
    case "${VERSION_ID:-}" in
        22.04|24.04|20.04) ok "Ubuntu $VERSION_ID is a tested Coyote host" ;;
        *) warn "Untested distribution; Coyote is verified on Ubuntu 20.04/22.04/24.04" ;;
    esac
else
    warn "/etc/os-release not readable"
fi

KVER=$(uname -r)
KMAJ=${KVER%%.*}
KMIN=$(echo "$KVER" | cut -d. -f2)
info "Kernel: $KVER"
if (( KMAJ > 5 || (KMAJ == 5 && KMIN >= 4) )); then
    ok "Kernel >= 5.4"
else
    bad "Kernel too old; Coyote needs >= 5 (tested on 5.4/5.15/6.2/6.8)"
fi

head_ "Kernel headers (needed to build the Coyote driver)"
if [[ -d "/lib/modules/$KVER/build" ]]; then
    ok "/lib/modules/$KVER/build present"
else
    bad "Missing headers. Install: sudo apt install linux-headers-$KVER"
fi

head_ "Build toolchain"
for tool in gcc g++ make cmake git python3 unzip; do
    if command -v "$tool" >/dev/null 2>&1; then
        ok "$tool -> $(command -v "$tool")"
    else
        bad "$tool not found"
    fi
done

if command -v cmake >/dev/null 2>&1; then
    CMV=$(cmake --version | head -1 | awk '{print $3}')
    info "CMake version: $CMV"
    CMAJ=${CMV%%.*}
    if (( CMAJ >= 3 )); then ok "CMake >= 3"; else bad "CMake >= 3.5 required"; fi
fi

head_ "Libraries"
if [[ -f /usr/include/boost/version.hpp ]]; then
    ok "Boost headers present"
else
    bad "Boost dev headers missing. Install: sudo apt install libboost-all-dev"
fi
if [[ -f /usr/include/uuid/uuid.h ]]; then
    ok "uuid headers present"
else
    bad "uuid dev headers missing. Install: sudo apt install uuid-dev"
fi

head_ "Hugepages (required by the Coyote runtime)"
HP_TOTAL=$(awk '/^HugePages_Total:/ {print $2}' /proc/meminfo)
HP_SIZE=$(awk '/^Hugepagesize:/ {print $2}' /proc/meminfo)
info "Hugepagesize: ${HP_SIZE} kB"
if [[ "${HP_TOTAL:-0}" -ge 1024 ]]; then
    ok "HugePages_Total = $HP_TOTAL (>= 1024)"
else
    bad "HugePages_Total = ${HP_TOTAL:-0}; run 10_setup_host.sh to reserve them"
fi

head_ "Alveo card on the PCIe bus"
mapfile -t XDEVS < <(lspci -Dn -d 10ee: 2>/dev/null | awk '{print $1}')
if (( ${#XDEVS[@]} == 0 )); then
    bad "No Xilinx (vendor 10ee) PCIe device found"
else
    for bdf in "${XDEVS[@]}"; do
        DID=$(cat "/sys/bus/pci/devices/$bdf/device" 2>/dev/null)
        SDID=$(cat "/sys/bus/pci/devices/$bdf/subsystem_device" 2>/dev/null)
        info "Found $bdf  device=$DID  subsystem=$SDID"
        case "${DID,,}" in
            0xd004)
                ok "$bdf = U250 factory (golden/manufacturing) image -> ready to flash over PCIe"
                ;;
            0x903f)
                ok "$bdf = Coyote bitstream already loaded (XDMA 0x903F)"
                ;;
            0x5004|0x5005)
                warn "$bdf = U250 with an XRT shell; Coyote will replace it"
                ;;
            *)
                warn "$bdf = unrecognised device id $DID (custom bitstream?)"
                ;;
        esac
        LNK_SPD=$(cat "/sys/bus/pci/devices/$bdf/current_link_speed" 2>/dev/null || echo "?")
        LNK_WID=$(cat "/sys/bus/pci/devices/$bdf/current_link_width" 2>/dev/null || echo "?")
        info "  link: $LNK_SPD x$LNK_WID"
    done
fi

head_ "BIOS: Above 4G Decoding"
# Coyote's static layer requests 64-bit BARs. Look for any PCI BAR mapped above
# the 4 GiB boundary; that only happens when Above-4G-Decoding is enabled.
ABOVE_4G=0
for res in /sys/bus/pci/devices/*/resource; do
    [[ -r "$res" ]] || continue
    while read -r start _ flags; do
        # Memory BARs only (bit 8 of flags marks I/O space on Linux).
        [[ "$start" == "0x0000000000000000" ]] && continue
        if (( ${flags:-0} & 0x100 )); then continue; fi
        if (( start > 0x100000000 )); then ABOVE_4G=1; break 2; fi
    done < "$res"
done
if (( ABOVE_4G )); then
    ok "Found a PCI BAR above 4 GiB -> Above 4G Decoding is enabled"
else
    warn "No BAR above 4 GiB found. If PCIe rescan fails after flashing,"
    warn "enable 'Above 4G Decoding' in the BIOS."
fi

head_ "Secure Boot (must be off to insmod an unsigned module)"
if command -v mokutil >/dev/null 2>&1; then
    SB=$(mokutil --sb-state 2>/dev/null || true)
    if echo "$SB" | grep -qi "disabled"; then
        ok "Secure Boot disabled"
    elif echo "$SB" | grep -qi "enabled"; then
        bad "Secure BootENABLED -- unsigned coyote_driver.ko will be refused"
    else
        warn "Secure Boot state unknown"
    fi
else
    warn "mokutil not installed; cannot check Secure Boot"
fi

head_ "IPMI / BMC (for remote cold reboot after flashing)"
if [[ -e /dev/ipmi0 || -e /dev/ipmi/0 ]]; then
    ok "IPMI device node present -> remote cold power-cycle possible"
    command -v ipmitool >/dev/null 2>&1 \
        && ok "ipmitool installed" \
        || warn "ipmitool missing. Install: sudo apt install ipmitool"
else
    warn "No IPMI node. A cold reboot will need physical/other out-of-band access."
fi

head_ "Vivado"
if command -v vivado >/dev/null 2>&1; then
    VV=$(vivado -version 2>/dev/null | head -1 || echo "unknown")
    info "$VV"
    if echo "$VV" | grep -q "v2022.1"; then
        ok "Vivado 2022.1 -- matches Coyote's pre-built U250 static checkpoint"
    else
        warn "Coyote's U250 static checkpoint was built with Vivado v2022.1.2."
        warn "Other versions require rebuilding the static layer (BUILD_STATIC=1)."
    fi
else
    bad "vivado not on PATH. Source its settings64.sh, or install it."
fi

head_ "Disk space"
AVAIL_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
info "Free on /: ${AVAIL_GB} GB"
if (( AVAIL_GB >= 200 )); then
    ok "Enough room for Vivado plus a build tree"
else
    warn "Less than 200 GB free; Vivado (~120 GB) plus builds may not fit"
fi

printf '\n== Summary ==\n'
printf '  passed: %d   failed: %d   warnings: %d\n' "$PASS" "$FAIL" "$WARN"
if (( FAIL > 0 )); then
    printf '\nResolve the [FAIL] items before continuing.\n'
    exit 1
fi
printf '\nAll mandatory checks passed.\n'
exit 0
