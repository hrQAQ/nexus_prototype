#!/usr/bin/env python3
"""
21_probe_flash.py -- Read-only reachability check for the Alveo AXI Quad SPI
                flash controller.

WHAT THIS DOES
    Maps the card's BAR0 read-only and reads a few AXI Quad SPI registers to
    confirm the flash controller exposed by the factory (golden) image responds
    over PCIe. That reachability is the precondition for flashing without JTAG.

WHAT THIS DOES NOT DO
    It performs no writes of any kind. It cannot damage the card.

Register offsets and the controller base address are taken from XRT's
src/runtime_src/core/pcie/tools/xbflash.qspi/xspi.cpp:
    #define FLASH_BASE 0x040000
    XSP_CR_OFFSET 0x60, XSP_SR_OFFSET 0x64, XSP_SSR_OFFSET 0x70,
    XSP_TFO_OFFSET 0x74, XSP_RFO_OFFSET 0x78

Requires root (BAR access via sysfs) and the device's memory decoding enabled:
    echo 1 | sudo tee /sys/bus/pci/devices/<BDF>/enable

Usage:
    sudo ./21_probe_flash.py [BDF]
    sudo ./21_probe_flash.py 0000:1a:00.0
"""

import argparse
import mmap
import os
import re
import sys

FLASH_BASE = 0x040000

REGISTERS = (
    (0x60, "CR  (Control)"),
    (0x64, "SR  (Status)"),
    (0x70, "SSR (Slave Select)"),
    (0x74, "TFO (Tx FIFO occupancy)"),
    (0x78, "RFO (Rx FIFO occupancy)"),
)

# AXI Quad SPI reset values, per Xilinx PG153.
CR_RESET = 0x180
SR_RESET = 0xA5

BDF_RE = re.compile(r"^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$")


def find_xilinx_devices():
    """Return sysfs BDFs of all PCI devices with Xilinx vendor id 0x10ee."""
    base = "/sys/bus/pci/devices"
    found = []
    for name in sorted(os.listdir(base)):
        try:
            with open(os.path.join(base, name, "vendor")) as fh:
                if fh.read().strip().lower() == "0x10ee":
                    found.append(name)
        except OSError:
            continue
    return found


def main():
    ap = argparse.ArgumentParser(
        description="Read-only probe of the Alveo AXI Quad SPI flash controller."
    )
    ap.add_argument(
        "bdf",
        nargs="?",
        help="PCI address, e.g. 0000:1a:00.0. Autodetected if omitted.",
    )
    args = ap.parse_args()

    if args.bdf:
        if not BDF_RE.match(args.bdf):
            sys.exit(f"error: '{args.bdf}' is not a valid BDF (expected 0000:1a:00.0)")
        bdf = args.bdf
    else:
        devs = find_xilinx_devices()
        if not devs:
            sys.exit("error: no Xilinx (0x10ee) PCI device found")
        if len(devs) > 1:
            sys.exit("error: multiple Xilinx devices found, pass one explicitly: "
                     + ", ".join(devs))
        bdf = devs[0]

    devdir = f"/sys/bus/pci/devices/{bdf}"
    resource = f"{devdir}/resource0"

    if not os.path.exists(resource):
        sys.exit(f"error: {resource} not found")

    try:
        with open(f"{devdir}/device") as fh:
            devid = fh.read().strip()
    except OSError:
        devid = "?"

    size = os.path.getsize(resource)

    print(f"Device      : {bdf}")
    print(f"Device ID   : {devid}", end="")
    if devid.lower() == "0xd004":
        print("  (U250 factory/golden image)")
    elif devid.lower() == "0x903f":
        print("  (Coyote XDMA bitstream already loaded)")
    else:
        print()
    print(f"BAR0 size   : {size} bytes ({size // (1024 * 1024)} MB)")
    print(f"Flash base  : 0x{FLASH_BASE:06x}")

    if FLASH_BASE + 0x100 > size:
        sys.exit("error: flash controller offset lies outside BAR0")

    # Confirm memory decoding is on, otherwise reads return all ones.
    try:
        with open(f"{devdir}/enable") as fh:
            if fh.read().strip() == "0":
                print("\nNOTE: memory decoding is disabled for this device.")
                print(f"      Enable it with:  echo 1 | sudo tee {devdir}/enable")
    except OSError:
        pass

    pagesize = mmap.PAGESIZE
    map_off = (FLASH_BASE // pagesize) * pagesize
    delta = FLASH_BASE - map_off

    values = {}
    try:
        with open(resource, "rb") as fh:
            mm = mmap.mmap(fh.fileno(), pagesize, mmap.MAP_SHARED,
                           mmap.PROT_READ, offset=map_off)
            try:
                print("\nAXI Quad SPI registers (read-only):")
                for off, name in REGISTERS:
                    raw = mm[delta + off: delta + off + 4]
                    val = int.from_bytes(raw, "little")
                    values[off] = val
                    print(f"  +0x{off:02x}  {name:24s} = 0x{val:08x}")
            finally:
                mm.close()
    except PermissionError:
        sys.exit("error: permission denied. Re-run with sudo.")

    print()
    vals = list(values.values())
    if all(v == 0xFFFFFFFF for v in vals):
        print("VERDICT: FAIL -- every read returned 0xFFFFFFFF.")
        print("         BAR0 is not decoding, or there is no flash controller here.")
        return 1
    if all(v == 0 for v in vals):
        print("VERDICT: FAIL -- every read returned 0x00000000.")
        return 1

    print("VERDICT: PASS -- the AXI Quad SPI flash controller is reachable over PCIe.")
    if values.get(0x60) == CR_RESET and values.get(0x64) == SR_RESET:
        print(f"         CR=0x{CR_RESET:x} and SR=0x{SR_RESET:x} are the documented")
        print("         reset values (Xilinx PG153): controller is idle and healthy.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
