# 阶段 0 —— 主机准备

**耗时：** 约 10 分钟 · **是否碰硬件：** 否 · **风险：** 无

目标：确认这台机器能跑 Coyote，并把所有不依赖 Vivado 的东西装好。

---

## 0.1 克隆代码仓库

```bash
mkdir -p ~/fpga && cd ~/fpga

# Coyote，必须带子模块（网络栈是子模块）
git clone --recurse-submodules https://github.com/fpgasystems/Coyote.git

# XRT，仅用于编译 xbflash2，浅克隆足够
git clone --depth 1 https://github.com/Xilinx/XRT.git
```

如果访问 GitHub 较慢，用镜像也没问题，我们只关心源码内容。

确认子模块拉下来了（网络栈缺失会导致后续构建失败）：

```bash
cd ~/fpga/Coyote && git submodule status
```

应该看到 `hw/services/network` 这一行，且行首**没有** `-` 号。

---

## 0.2 环境审计

```bash
cd <本文档目录>/scripts
./00_check_env.sh
```

这个脚本是只读的。它检查内核、内核头文件、编译工具链、库、hugepages、PCIe 上的板卡、
Above-4G 解码、Secure Boot、IPMI、Vivado 和磁盘空间。

在一台全新机器上，预期会看到若干 `[FAIL]`（缺包、缺 Vivado）。下面两步解决缺包问题，Vivado 是
阶段 1 的事。

### 如何理解板卡检查结果

脚本会解码 PCI device id：

| Device id | 含义 | 应对|
|---|---|---|
| `0xd004` | U250 出厂（golden）镜像 | 最理想的起点 |
| `0x903f` | 已经烧了 Coyote bitstream | 板卡已就绪 |
| `0x5004` / `0x5005` | 装了 XRT shell 的 U250 | Coyote 会替换掉它 |
| 其他 | 自定义 bitstream | 见下方警告 |

> **如果 id 不是 `0xd004`，说明 flash 里已经有东西了。** 烧写 Coyote 会覆盖**用户区**。请确认
> 那个设计可以重新生成，或先做备份。

可以自己去 XRT 源码里确认 `0xd004` 确实是出厂镜像：

```bash
grep -rn "0xD004" XRT/src/runtime_src/core/pcie/driver/linux/xocl/devices.h
# { XOCL_PCI_DEVID(0x10EE, 0xD004, PCI_ANY_ID, XBB_MFG("u250")) },
```

`XBB_MFG` 就是 manufacturing image（生产镜像）的缩写。

---

## 0.3 安装依赖并预留 hugepages

```bash
sudo ./10_setup_host.sh
```

它会安装 `build-essential`、`cmake`、`linux-headers-$(uname -r)`、`libboost-all-dev`、
`uuid-dev`、`ipmitool` 等，然后预留 2048 个 2 MB hugepage（共 4 GB），并写入
`/etc/sysctl.d/99-coyote-hugepages.conf` 实现持久化。

需要更多可以这样：

```bash
sudo ./10_setup_host.sh --hugepages 4096   # 8 GB
```

### 为什么 hugepages 是必需的

Coyote 运行时用 `MAP_HUGETLB`分配 DMA 缓冲：

```cpp
// Coyote/sw/src/cThread.cpp
MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | huge_flag,
```

并且把页大小定义为 2 MB：

```cpp
// Coyote/sw/include/coyote/cDefs.hpp
constexpr unsigned long long const HUGE_PAGE_SIZE = (2ULL * 1024ULL * 1024ULL);
```

`MAP_HUGETLB` 只能从**预先保留的页池**中分配。没有预留，每次分配都会以
`Hugepage allocation failed` 失败。

确认：

```bash
grep -E 'HugePages_Total|HugePages_Free' /proc/meminfo
```

如果实际数量少于请求值，说明物理内存碎片化了 —— 重启后重跑，或者少要一些。

---

## 0.4 处理剩余的警告

### Secure Boot 必须关闭

```bash
mokutil --sb-state
```

`coyote_driver.ko` 没有签名，开启 Secure Boot 的机器会拒绝加载它。请在 BIOS 里关闭 Secure
Boot，或者自己给模块签名（本文不涉及）。

### Above 4G Decoding 必须开启

Coyote 的静态层需要 64 位 BAR。`00_check_env.sh` 通过查找是否存在映射到 4 GiB 以上的 PCI BAR
来推断这个设置。如果它报警告，请在 BIOS 里开启 **Above 4G Decoding**（有时叫
"64-bit BAR support" 或 "Large BAR support"）。

关闭时的典型症状：烧写并重启后板卡能看到，但 `lspci` 显示 BAR 为 `[disabled]`，驱动无法映射。

### IPMI 用于远程冷启动

阶段 4 要求**冷**启动 —— 完全断电。热重启（`reboot`）不会让FPGA 重新读 flash。

```bash
ls /dev/ipmi0
sudo ipmitool mc info
```

有 IPMI 的话，`sudo ipmitool chassis power cycle` 就能远程搞定。没有的话，**在烧写之前**先安排
好断电手段。

---

## 0.5 重新审计

```bash
./00_check_env.sh
```

此时除 Vivado 外应该全部通过。

---

## 验收标准

- [ ] `Coyote` 与 `XRT` 已克隆，`hw/services/network` 子模块存在
- [ ] `00_check_env.sh` 除Vivado 外没有 `[FAIL]`
- [ ] `HugePages_Total` ≥ 1024
- [ ] Secure Boot 已关闭
- [ ] Above 4G Decoding 已确认开启
- [ ] 板卡可见，device id 已记录

下一步：[02-vivado-install.md](02-vivado-install.md)
