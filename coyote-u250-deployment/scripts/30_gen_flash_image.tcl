########################################################################################
# 30_gen_flash_image.tcl -- Turn a Coyote routed checkpoint into a flashable image.
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# Coyote targets JTAG programming only. Its U250 constraint files
# (hw/constraints/u250/**) set nothing but BITSTREAM.GENERAL.COMPRESS, so a
# stock `make bitgen` produces a .bit that carries no SPI-flash boot settings.
# Loading such an image from flash either fails outright or falls back to the
# slowest x1 bus width.
#
# This script re-opens the routed checkpoint, applies the flash-boot properties
# that AMD documents for the U250 (UG1289), and emits:
#   * cyt_top_flash.bit                  -- bitstream with flash-boot settings
#   * coyote_u250_primary.mcs\ the pair consumed by
#   * coyote_u250_secondary.mcs /  `xbflash2 program --spi --dual-flash`
#
# It does NOT modify the Coyote source tree, so Coyote stays upgradeable.
#
# FLASH LAYOUT (U250, two Micron MT25QU01G devices in dual-Quad-SPI / x8 mode)
#   0x00000000  factory golden image  <- never written by this flow
#   0x01002000  user image            <- our target
# The 0x01002000 offset is not arbitrary: XRT hard-codes it as
# `dftBitstreamGuardAddress` in xbflash.qspi/xspi.cpp. Because the address is
# non-zero, xbflash2 automatically installs a "bitstream guard" before writing
# and clears it only on success, so an interrupted flash falls back to golden.
#
# USAGE
#   vivado -mode batch -source 30_gen_flash_image.tcl -tclargs <build_hw_dir> [out_dir]
#
#<build_hw_dir>Coyote hardware build directory (contains checkpoints/)
#   [out_dir]       Output directory (default: <build_hw_dir>/flash)
########################################################################################

if {$argc < 1} {
    puts "ERROR: usage: vivado -mode batch -source 30_gen_flash_image.tcl -tclargs <build_hw_dir> \[out_dir\]"
    exit 1
}

set build_dir [lindex $argv 0]
if {$argc >= 2} {
    set out_dir [lindex $argv 1]
} else {
    set out_dir "$build_dir/flash"
}

# ---------------------------------------------------------------------------
# Locate the routed checkpoint produced by `make shell`.
# ---------------------------------------------------------------------------
set dcp_candidates [list \
    "$build_dir/checkpoints/shell_routed.dcp" \
    "$build_dir/checkpoints/shell_recombined.dcp" \
]

set dcp ""
foreach c $dcp_candidates {
    if {[file exists $c]} { set dcp $c; break }
}

if {$dcp eq ""} {
    puts "ERROR: no routed checkpoint found. Looked for:"
    foreach c $dcp_candidates { puts "  $c" }
    puts "Run 'make shell' (or 'make bitgen') in the Coyote hardware build first."
    exit 1
}

file mkdir $out_dir

puts "== Opening checkpoint =="
puts "  $dcp"
open_checkpoint $dcp

# Guard against pointing this script at a non-U250 build.
set part [get_property PART [current_design]]
puts "  part: $part"
if {![string match "xcu250*" $part]} {
    puts "ERROR: this script encodes U250-specific flash settings, but the design"
    puts "       targets '$part'. Refusing to continue."
    exit 1
}

# ---------------------------------------------------------------------------
# Flash-boot properties for the Alveo U250.
#
# Two Micron MT25QU01G (1 Gb each) wired as a dual Quad-SPI pair, presented to
# the FPGA as an x8 interface. Values follow AMD UG1289 for the U200/U250.
# ---------------------------------------------------------------------------
puts "== Applying U250 flash-boot properties =="

# Configuration interface: must match write_cfgmem -interface below.
set_property CONFIG_MODE                SPIx8       [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH      8           [current_design]

# 1 Gb devices exceed the 128Mb reachable with 24-bit addressing.
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR    YES         [current_design]

# Clocking. The FPGA drives CCLK itself (master SPI), sampling on the falling edge.
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE     YES         [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE63.8        [current_design]
set_property BITSTREAM.CONFIG.EXTMASTERCCLK_EN  disable     [current_design]

# Anti-brick: if this image fails its CRC, the FPGA reverts to the golden image.
set_property BITSTREAM.CONFIG.CONFIGFALLBACK    Enable      [current_design]
set_property BITSTREAM.CONFIG.TIMER_CFG         0x0001FFFF  [current_design]

# Board electricals and general settings.
set_property BITSTREAM.CONFIG.UNUSEDPIN         Pullup      [current_design]
set_property BITSTREAM.GENERAL.COMPRESS         TRUE        [current_design]
set_property CFGBVS                             GND         [current_design]
set_property CONFIG_VOLTAGE                     1.8         [current_design]

puts "== Effective configuration properties =="
foreach p {CONFIG_MODE CONFIG_VOLTAGE CFGBVS
           BITSTREAM.CONFIG.SPI_BUSWIDTH
           BITSTREAM.CONFIG.SPI_32BIT_ADDR
           BITSTREAM.CONFIG.SPI_FALL_EDGE
           BITSTREAM.CONFIG.CONFIGRATE
           BITSTREAM.CONFIG.CONFIGFALLBACK
           BITSTREAM.GENERAL.COMPRESS} {
    if {[catch {set v [get_property $p [current_design]]}]} {
        puts [format "  %-38s <unavailable>" $p]
    } else {
        puts [format "  %-38s %s" $p $v]
    }
}

# ---------------------------------------------------------------------------
# Bitstream
# ---------------------------------------------------------------------------
set bit_file "$out_dir/cyt_top_flash.bit"
puts "== Writing bitstream =="
puts "  $bit_file"
write_bitstream -force -no_partial_bitfile $bit_file

# ---------------------------------------------------------------------------
# Memory configuration files.
#
# -size is the per-device capacity in MB (MT25QU01G = 1 Gb = 128 MB).
# -interface SPIx8 makes write_cfgmem split the stream across both devices and
# emit *_primary.mcs / *_secondary.mcs, exactly the pair that xbflash2 expects
# from `--dual-flash`.
# ---------------------------------------------------------------------------
set mcs_stem "$out_dir/coyote_u250"
set user_offset 0x01002000

puts "== Writing memory configuration files =="
puts "  stem   : $mcs_stem"
puts "  offset : $user_offset (user partition; golden image at 0x0 untouched)"

write_cfgmem -force -format mcs \
    -size 128 \
    -interface SPIx8 \
    -loadbit "up $user_offset $bit_file" \
    -checksum \
    -file $mcs_stem

close_project

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
puts ""
puts "== Generated files =="
set expected [list \
    "$bit_file" \
    "${mcs_stem}_primary.mcs" \
    "${mcs_stem}_secondary.mcs" \
]
set missing 0
foreach f $expected {
    if {[file exists $f]} {
        puts [format "  %-52s %s bytes" [file tail $f] [file size $f]]
    } else {
        puts [format "  %-52s MISSING" [file tail $f]]
        set missing 1
    }
}

if {$missing} {
    puts""
    puts "ERROR: expected outputs are missing. Check the log above."
    exit 1
}

puts ""
puts "Next step: flash over PCIe with"
puts "  sudo ./40_flash_over_pcie.sh --mcs-stem $mcs_stem --device <BDF>"
exit 0
