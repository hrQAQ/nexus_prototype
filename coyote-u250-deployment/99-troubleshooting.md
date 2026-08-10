# 故障排查

按问题出现的阶段组织。

---

## 先收集诊断信息

```bash
# 板卡与链路
lspci -Dn -d 10ee:
BDF=$(lspci -Dn -d 10ee: | awk '{print $1}' | head -1)
sudo lspci -vvv -s "${BDF#0000:}"

# 内核视角
dmesg | tail -60
lsmod | grep -E "coyote|xocl|xclmgmt|ami"
basename "$(readlink /sys/bus/pci/devices/$BDF/driver 2>/dev/null)" 2>/dev/null

# 主机状态
grep -E "HugePages_Total|HugePages_Free" /proc/meminfo
uname -r
mokutil --sb-state

# 重新审计
./scripts/00_check_env.sh
```

---

## 阶段 0–2：主机与编译

### 编译驱动时报缺少内核头文件

```
fatal error: linux/module.h: No such file or directory
```

```bash
sudo apt-get install -y "linux-headers-$(uname -r)"
```

如果这个包不存在，说明你的内核不是发行版仓库里的。请安装匹配的头文件，或改用发行版内核启动。

### CMake 找不到 Boost

```
CMake Error: Could NOT find Boost (missing: Boost_INCLUDE_DIR)
```

只有运行时库不够，需要头文件：

```bash
sudo apt-get install -y libboost-all-dev
```

### 编译 `xbflash2` 时报缺少 `uuid/uuid.h`

```bash
sudo apt-get install -y uuid-dev
```

### 编译 `xbflash2` 时报缺少 `tools/common/*.h` 或 `xcl_graph.h`

include 路径不对，通常是因为 `--xrt-src` 没有指向 `src` 目录：

```bash
./20_build_xbflash2.sh --xrt-src /path/to/XRT/src   # 注意结尾的 src
```

确认这两个目录存在：

```bash
ls /path/to/XRT/src/runtime_src/core/tools/xbflash2
ls /path/to/XRT/src/runtime_src/core/pcie/tools/xbflash.qspi
```

### hugepages 达不到请求的数量

```bash
cat /proc/sys/vm/nr_hugepages     # 少于请求值
```

物理内存碎片化了。要么重启后重跑 `10_setup_host.sh`，要么少要一些。**越早在启动流程中预留越
可靠** —— 脚本写入的 sysctl 配置就是为此。

---

## 阶段 2：flash 探测

### 探测结果全是 `0xFFFFFFFF`

BAR0 没有解码。没有驱动绑定时，Linux 默认关闭内存解码：

```bash
echo 1 | sudo tee /sys/bus/pci/devices/$BDF/enable
cat /sys/bus/pci/devices/$BDF/enable # 期望 1
sudo lspci -vv -s "${BDF#0000:}" | grep "Control:"   # 期望 Mem+
```

如果仍然全是 1，检查 `lspci` 里 BAR 是否标记为 `[disabled]`。那通常意味着
**BIOS 里Above 4G Decoding 是关闭的**。

### 探测结果全是 `0x00000000`

BAR0+`0x40000` 处没有 flash 控制器。可能原因：

- 板卡跑的不是出厂镜像，而当前设计没有暴露 AXI Quad SPI 控制器。检查 device id：只有 `0xd004`
  才能保证出厂布局。
- 板卡不是 U250。

**如果 flash 控制器不可达，PCIe 这条路就是不通的**，只能用 JTAG。

### 探测报 permission denied

用 `sudo` 运行。通过 sysfs 访问 BAR 需要 root。

---

## 阶段 3：综合

### CMake 不接受 `FDEV_NAME`

```bash
cmake ../ -DFDEV_NAME=u250     # 必须是小写的 u250
```

合法取值见 `cmake/FindCoyoteHW.cmake`：`u250`、`u280`、`u55c`、`v80`。

### 静态层 checkpoint 报版本不匹配

```
ERROR: This design checkpoint was created with a different version of Vivado
```

你用的不是 2022.1。要么装2022.1，要么重建静态层：

```bash
cmake ../ -DFDEV_NAME=u250 -DBUILD_STATIC=1
```

重建要多花 10–15 小时，还可能需要改源码。**装 2022.1 几乎总是更划算。**

### 报缺少 CMAC license

```
ERROR: [Common 17-69] licensing ... cmac_usplus
```

Coyote 的网络功能需要付费的 `cmac_usplus`。非网络示例保持 `EN_NET=0`（默认值）即可。查看你有
哪些 feature：

```bash
grep -o "INCREMENT [a-zA-Z0-9_]*" "$XILINXD_LICENSE_FILE" | sort -u
```

**`ernic`/`etrnic` 不是替代品** —— Coyote 用的是 Integrated 100G Ethernet Subsystem。

### 时序违例

```bash
grep -iE "timing constraints are not met" bitgen.log
```

确认示例的 `CMakeLists.txt` 里有 `BUILD_OPT 1`。轻微违例通常能工作，但可能导致偶发故障；如果
阶段 5 出现结果错误，要把这里当成可能原因。

### `30_gen_flash_image.tcl` 找不到 checkpoint

```
ERROR: no routed checkpoint found
```

布局布线还没完成。执行 `make shell`（或完整的 `make bitgen`），然后确认：

```bash
ls build_hw/checkpoints/shell_routed.dcp
```

### `write_cfgmem` 不接受 `-size` 或 `-interface`

TCL 脚本里的这些参数是**未经验证**的（见
[04-build-hardware.md](04-build-hardware.md#未验证的参数重要)）。让 Vivado 告诉你它认识哪些
flash 器件：

```bash
vivado -mode tcl
# 然后执行：
get_cfgmem_parts *mt25qu01g*
report_property [lindex [get_cfgmem_parts *mt25qu01g*] 0]
```

对照你板卡版本的 UG1289，然后修改 `30_gen_flash_image.tcl`。常见替代值：`-size 256`，或
`-interface SPIx4`。

---

## 阶段 4：烧写

### `xbflash2` 报设备被占用

```bash
sudo rmmod coyote_driver
sudo rmmod xocl xclmgmt ami 2>/dev/null
lsmod | grep -E "coyote|xocl|xclmgmt|ami"   # 应该为空
```

### 烧写中途失败

bitstream guard 仍然生效，板卡会启动 golden。重试：

```bash
sudo ./40_flash_over_pcie.sh --mcs-stem <stem>
```

如果每次都在同一位置失败，可能是flash 扇区损坏。先恢复出厂再重新评估：

```bash
sudo ./40_flash_over_pcie.sh --revert-to-golden
```

### 冷启动后板卡仍显示 `0xd004`

FPGA 回落到了 golden。按顺序排查：

1. **真的是冷启动吗？** 热重启不会重读 flash。用`ipmitool chassis power cycle` 或物理断电。
2. **位宽与寻址模式。** 确认 TCL 日志显示 `CONFIG_MODE = SPIx8` 且 `SPI_32BIT_ADDR = YES`。
3. **镜像偏移。** `head -3 coyote_u250_primary.mcs` 应该有扩展地址记录，而不是从 0 开始的数据。
4. **CRC 失败。** `CONFIGFALLBACK` 起作用了。重新生成 MCS 再试。

### 冷启动后板卡完全消失

```bash
echo 1 | sudo tee /sys/bus/pci/rescan
lspci -Dn -d 10ee:
```

**重扫描后出现** —— FPGA 配置成功但晚于 BIOS 枚举，即时序风险。缓解：

- 延长 POST（完整内存训练、关闭快速启动），给 FPGA 更多时间。
- 确认 x8 位宽真的生效，让加载尽可能快。
- 权宜之计：把重扫描做成开机服务。

**重扫描后仍然没有** —— 恢复出厂并冷启动：

```bash
sudo ./40_flash_over_pcie.sh --revert-to-golden --device $BDF
sudo ipmitool chassis power cycle
```

如果板卡不可见，`xbflash2` 无从下手，此时需要 JTAG。这要求 golden 区被损坏，而本流程从不写该
区域。

---

## 阶段 5：驱动与运行时

### `insmod` 报 "Invalid module format"

模块是为别的内核编译的：

```bash
modinfo coyote_driver.ko | grep vermagic
uname -r
```

在本机重新编译：

```bash
cd Coyote/driver && make clean && make TARGET_PLATFORM=ultrascale_plus
```

### `insmod` 报 "Operation not permitted"

Secure Boot 在拒绝未签名模块：

```bash
mokutil --sb-state
```

在 BIOS 里关闭 Secure Boot，或给模块签名。

### 驱动加载了但没有 `probe returning 0`

模块在内存里但没有绑定设备。检查 device id —— 驱动只匹配 `0x903F` 等：

```bash
cat /sys/bus/pci/devices/$BDF/device
```

如果是 `0xd004`，说明板卡上跑的并不是 Coyote，回到阶段 4。

也要确认编译时选了正确的平台。`versal` 编出来的是 QDMA，永远无法绑定 U250：

```bash
cd Coyote/driver && make clean && make TARGET_PLATFORM=ultrascale_plus
```

### `dmesg` 显示 BAR 映射失败

```
could not map BAR0
```

很可能 Above 4G Decoding 关闭，或 BAR 分配失败。检查：

```bash
sudo lspci -vv -s "${BDF#0000:}" | grep -E "Region|disabled"
```

出现 `[disabled]`，或只分配到32 位地址，都指向 BIOS 设置。

### probe 成功但 `/dev/fpga_0` 不存在

```bash
ls -l /dev/fpga*
dmesg | grep -i "char device\|cdev\|class"
```

字符设备创建失败。上次加载残留的设备节点可能冲突：

```bash
sudo rmmod coyote_driver
sudo rm -f /dev/fpga*
sudo insmod .../coyote_driver.ko
```

### 示例报 "Hugepage allocation failed"

```bash
grep -E "HugePages_Total|HugePages_Free" /proc/meminfo
sudo ./10_setup_host.sh --hugepages 4096
```

注意这条报错还会打印 shell 的 `pg_l_bits`。如果硬件期望的页大小与主机的 2 MB hugepage 不匹配，
说明配置不一致。

### 示例卡住

几乎总是 page fault 或 TLB 问题：

```bash
dmesg | tail -40 | grep -iE "page fault|tlb|invalid"
```

用 `sudo rmmod coyote_driver` 恢复，然后重新加载。如果稳定复现，可能是 bitstream 有时序违例，
回查 `bitgen.log`。

### 示例返回错误数据

**优先怀疑 bitstream，而不是软件。** 确认时序收敛，并确认 flash 里的镜像确实是你以为的那个。
用已知正常的 MCS 重新烧写。

---

## 彻底重置

把板卡恢复出厂、主机恢复干净：

```bash
sudo rmmod coyote_driver 2>/dev/null
sudo ./scripts/40_flash_over_pcie.sh --revert-to-golden --device $BDF
sudo ipmitool chassis power cycle
# 启动后：
lspci -Dn -d 10ee:      # 期望 0xd004
```

---

## 去哪里提问

- Coyote 的 [discussions](https://github.com/fpgasystems/Coyote/discussions) 和
  [FAQ](https://fpgasystems.github.io/Coyote/intro/faq.html)
- `xbflash2` 相关问题去 XRT 的 [issues](https://github.com/Xilinx/XRT/issues)
- Alveo 硬件与 flash 布局问题去 AMD [支持论坛](https://adaptivesupport.amd.com/)

提问时请附上：板卡 device id、Vivado 版本、内核版本、相关的 `dmesg` 片段，以及失败发生在哪个
阶段。
