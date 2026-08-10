# 阶段 2 —— 编译驱动与软件

**耗时：** 约 5 分钟 · **是否碰硬件：** 否 · **风险：** 无

本阶段全部内容**已在硬件上验证**（Ubuntu 22.04，内核 6.8.0-110）。不需要 Vivado，所以可以和
阶段 1 并行进行。

---

## 2.1 编译内核驱动

```bash
cd ~/fpga/Coyote/driver
make TARGET_PLATFORM=ultrascale_plus
```

`TARGET_PLATFORM` 决定使用哪个 DMA 引擎，选错会得到一个永远无法绑定的模块：

| 取值 | 适用设备 | DMA 引擎 |
|---|---|---|
| `ultrascale_plus` | **U250**、U280、U55C | XDMA |
| `versal` | V80 | QDMA |

U250 是 UltraScale+ 器件，所以 `ultrascale_plus` 是正确的。

产物：

```bash
ls -l build/coyote_driver.ko
```

大约 7 MB。

### 确认模块能匹配你的板卡

```bash
modinfo build/coyote_driver.ko | grep -c "alias:.*d0000903F"
```

预期输出 `1`。Coyote 的 bitstream 会呈现 PCI device id `0x903F`，这个值硬编码在
`hw/bd/ultrascale_plus/cr_pci.tcl`：

```tcl
CONFIG.pf0_device_id {903F}
```

驱动侧在 `driver/src/platform/pci_xdma.c` 中匹配它：

```c
{ PCI_DEVICE(0x10ee, 0x903F), },
```

所以烧写完成后，板卡必须显示为 `10ee:903f`，驱动才能绑定。

### 注意事项

- **必须在部署机上编译。** 模块与运行中的内核绑定，在别的机器上编译的模块加载不了。
- 两个可以忽略的警告：
  - `warning: the compiler differs from the one used to build the kernel` —— 同样是
    gcc-12，只是打包方式不同。
  - `Skipping BTF generation... due to unavailability of vmlinux` —— 只影响调试元数据。
- **内核升级后必须重新编译。**

---

## 2.2 编译 Coyote 库与示例 1

```bash
cd ~/fpga/Coyote/examples/01_hello_world/sw
mkdir -p build_sw && cd build_sw
cmake ../
make -j"$(nproc)"
```

产物：

- `coyote/libcoyote.so` —— 运行时库
- `test` —— 示例 1 的可执行文件

```bash
ls -l test coyote/libcoyote.so
```

### 如果 CMake 找不到 Boost

```
CMake Error: Could NOT find Boost (missing: Boost_INCLUDE_DIR)
```

仅有运行时库不够，还需要头文件：

```bash
sudo apt-get install -y libboost-all-dev
```

然后重新执行 `cmake ../`。（`10_setup_host.sh` 已经处理了这个依赖。）

### 现在还不要运行 `./test`

它需要 `/dev/fpga*` 设备节点，而这只有在驱动绑定到已烧写 Coyote 的板卡后才会出现。现在运行会
报设备打开失败，这是**正常的**，要等到阶段 5。

---

## 2.3 编译 `xbflash2`

这就是让我们不需要 JTAG 的工具，从 AMD 的 XRT 源码编译。

```bash
cd <本文档目录>/scripts
./20_build_xbflash2.sh --xrt-src ~/fpga/XRT/src
```

产物：`scripts/build/xbflash2`。

验证：

```bash
./build/xbflash2 --help
./build/xbflash2 program --spi --help
```

第二条命令应该列出 `--image`、`--dual-flash` 和 `--revert-to-golden`。这三个选项是阶段 4 的
基础。

### 脚本做了什么，以及为什么这样做

`xbflash2` 在 AMD 那边是作为独立包发布的。为了避免安装整个 XRT，脚本只编译这一个二进制：

1. 生成 CMake 本来会从 git 元数据产出的三个版本头文件。
2. 按 `src/runtime_src/core/tools/xbflash2/CMakeLists.txt` 里的源文件清单编译，外加
   `src/runtime_src/core/pcie/tools/xbflash.qspi/` 下的共享 flash 后端。
3. 链接 Boost、pthread 和 libuuid。

**不涉及任何 XRT 内核模块。** 该工具通过 sysfs 把 BAR0 映射到用户空间来访问 flash 控制器：

```cpp
// XRT src/runtime_src/core/pcie/tools/xbflash.qspi/pcidev.cpp
user_bar_map = (char *)::mmap(0, user_bar_size, PROT_READ | PROT_WRITE, ...);
```

这就是为什么它不需要加载驱动，也能在只有出厂镜像的板卡上工作。

---

## 2.4 确认 flash 控制器可达

**在投入几小时综合之前先做这一步** —— 如果这里失败，PCIe 烧写这条路就是不通的，你还是得用
JTAG。

板卡的内存空间解码必须打开。没有驱动绑定时，Linux 默认是关闭的：

```bash
BDF=0000:1a:00.0          # 替换成你的，用 lspci -Dn -d 10ee: 查
echo 1 | sudo tee /sys/bus/pci/devices/$BDF/enable
```

这只是翻转 PCI command寄存器里的一个位，可逆（`echo 0` 关回去），无副作用。

然后探测：

```bash
sudo ./21_probe_flash.py
```

脚本**不执行任何写操作**。预期输出：

```
Device      : 0000:1a:00.0
Device ID   : 0xd004  (U250 factory/golden image)
BAR0 size   : 33554432 bytes (32 MB)
Flash base  : 0x040000

AXI Quad SPI registers (read-only):
  +0x60CR  (Control)            = 0x00000180
  +0x64  SR  (Status)             = 0x000000a5
  +0x70  SSR (Slave Select)       = 0x00000001
  +0x74  TFO (Tx FIFO occupancy)  = 0x00000000
  +0x78  RFO (Rx FIFO occupancy)  = 0x00000000

VERDICT: PASS -- the AXI Quad SPI flash controller is reachable over PCIe.
```

### 如何解读结果

`CR=0x180` 和 `SR=0xa5` 是 AXI Quad SPI IP 的**文档记载的复位值**（Xilinx PG153）：主模式 +
手动片选，两个 FIFO 都空。读到正好这两个值，说明控制器存在、空闲、健康。

失败模式：

| 现象 | 原因 |
|---|---|
| 全是 `0xFFFFFFFF` | BAR 没有解码 —— 是否忘了 `echo 1 > .../enable`？ |
| 全是 `0x00000000` | 该偏移处没有控制器；当前 bitstream 可能没有暴露 flash 控制器 |
| Permission denied | 需要用 `sudo` 运行 |

如果拿不到 PASS，**先停下来重新评估** —— 参见
[99-troubleshooting.md](99-troubleshooting.md)。

---

## 验收标准

- [ ] `driver/build/coyote_driver.ko` 存在，且包含 `0x903F` 的 alias
- [ ] `libcoyote.so` 与 `test` 编译成功
- [ ] `xbflash2` 可运行，且能列出 `--image` / `--dual-flash` / `--revert-to-golden`
- [ ] `21_probe_flash.py` 报告 **PASS**，且 `CR=0x180`、`SR=0xa5`

下一步：[04-build-hardware.md](04-build-hardware.md)
