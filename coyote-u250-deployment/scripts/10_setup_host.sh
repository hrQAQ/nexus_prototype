#!/usr/bin/env bash
#
# 10_setup_host.sh -- Install build dependencies and reserve hugepages.
#
# Idempotent: safe to re-run. Requires sudo.
#
# Usage: ./10_setup_host.sh [--hugepages N]
#
#   --hugepages N   Number of 2 MB hugepages to reserve (default 2048 = 4 GB).

set -euo pipefail

NR_HUGEPAGES=2048

while (( $# )); do
    case "$1" in
        --hugepages)
            [[ $# -ge 2 ]] || { echo "error: --hugepages needs a value" >&2; exit 1; }
            NR_HUGEPAGES=$2
            shift 2
            ;;
        -h|--help)
            sed -n '2,12p' "$0"; exit 0 ;;
        *)
            echo "error: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

if ! [[ "$NR_HUGEPAGES" =~ ^[0-9]+$ ]]; then
    echo "error: --hugepages must be a non-negative integer" >&2
    exit 1
fi

echo "== Installing packages =="
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    cmake \
    git \
    "linux-headers-$(uname -r)" \
    libboost-all-dev \
    uuid-dev \
    pkg-config \
    unzip \
    python3 \
    ipmitool \
    mokutil \
    pciutils

echo
echo "== Reserving $NR_HUGEPAGES x 2 MB hugepages ($((NR_HUGEPAGES * 2)) MB) =="

# Apply now.
echo "$NR_HUGEPAGES" | sudo tee /proc/sys/vm/nr_hugepages >/dev/null

# Persist across reboots.
SYSCTL_FILE=/etc/sysctl.d/99-coyote-hugepages.conf
printf 'vm.nr_hugepages = %s\n' "$NR_HUGEPAGES" | sudo tee "$SYSCTL_FILE" >/dev/null
echo "Wrote $SYSCTL_FILE"

echo
echo "== Result =="
grep -E 'HugePages_Total|HugePages_Free|Hugepagesize' /proc/meminfo

GOT=$(awk '/^HugePages_Total:/ {print $2}' /proc/meminfo)
if [[ "$GOT" -lt "$NR_HUGEPAGES" ]]; then
    echo
    echo "WARNING: only $GOT of $NR_HUGEPAGES hugepages were allocated."
    echo "Memory is likely fragmented. Reboot, or lower the request."
fi

echo
echo "Host setup complete."
