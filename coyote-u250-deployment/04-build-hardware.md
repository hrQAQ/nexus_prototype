# 阶段 3 —— 综合 bitstream

**耗时：** 3–6 小时 · **是否碰硬件：** 否 · **风险：** 无（只消耗 CPU 时间）

把 Coyote 源码编译成 U250 的 `.bit`，然后补上上游 Coyote 缺失的 flash 启动属性。

---

## 3.1 要构建什么

Coyote 采用三层嵌套综合：

| 层 | 内容 | 我们的做法 |
|---|---|---|
| 静态层 | PCIe、DMA、主机链路 | **复用预编译 checkpoint**（省 10 小时以上） |
| 动态层 shell | DDR 控制器、各类服务 | 综合 |
| 应用层 vFPGA | 示例 1 的逻辑 | 综合 |

复用静态层 checkpoint 正是 Vivado 必须为 2022.1 的原因。先确认它存在：

```bash
ls -lh ~/fpga/Coyote/hw/checkpoints/static_routed_locked_u250.dcp
```

约 77 MB。如果不存在，说明克隆时漏了 —— 重新克隆。

---

## 3.2 检查配置

```bash
cat ~/fpga/Coyote/examples/01_hello_world/hw/CMakeLists.txt
```

相关设置：

```cmake
set(EN_STRM 1)    # 主机内存数据流
set(EN_MEM 1)     # 板卡内存（U250 上是 DDR）
set(N_REGIONS 1)  # 一个 vFPGA
set(BUILD_OPT 1)  # 布局布线时开启优化
```

来自 `cmake/FindCoyoteHW.cmake` 的重要默认值：

| 变量 | 默认值 | 含义 |
|---|---|---|
| `BUILD_STATIC` | `0` | 复用静态层 checkpoint（**保持 0**） |
| `BUILD_SHELL` | `1` | 构建动态层 |
| `EN_PR` | `0` | 不启用部分重构 |
| `EN_NET` | `0` | 不启用网络 —— 因此不需要 CMAC license |

对 U250，`FDEV_NAME=u250` 会选中：

```cmake
set(FPGA_PART xcu250-figd2104-2L-e)
set(DDR_SIZE 34)      # 2^34 = 16 GB 每通道
set(N_DDR_CHAN 1)
set(HBM_SIZE 0)       # U250 没有 HBM
```

---

## 3.3 配置

```bash
source /tools/Xilinx/Vivado/2022.1/settings64.sh

cd ~/fpga/Coyote/examples/01_hello_world/hw
mkdir -p build_hw && cd build_hw

cmake ../ -DFDEV_NAME=u250
```

留意这几行输出：

```
** Target platform u250
** Coyote hardware configuration
```

如果 CMake 报错，**先解决再往下走** —— 在这里排查问题比在三小时综合之后便宜得多。

---

## 3.4 创建工程

```bash
make project
```

10–20 分钟。生成参数化后的源码，并执行必要的 HLS 编译。

---

## 3.5 综合与实现

**务必用 `screen` 或 `tmux`。** SSH 断开会杀死构建。

```bash
screen -S coyote_build
make bitgen 2>&1 | tee bitgen.log
# Ctrl-A 然后按 D 脱离；用 screen -r coyote_build 重新接入
```

`make bitgen` 会依次执行：

```
make synth   # 综合动态层与应用层
make link    # 与静态层 checkpoint 链接
make shell   # 布局布线
make bitgen  # 生成 bitstream
```

多核机器上预计 3–6 小时。监控进度：

```bash
tail -f bitgen.log
```

### 产物

```bash
ls -lh bitstreams/
```

我们需要的是 `cyt_top.bit` —— 完整镜像（静态层 + shell + 应用层）。`shell_top.bit` 和 `.bin`
文件用于运行时重构，本阶段不用。

### 时序收敛检查

```bash
grep -iE "timing constraints are not met|CRITICAL WARNING" bitgen.log | head
```

Coyote 给 U250 默认设置 `BUILD_OPT 1` 就是为了时序。轻微违例通常也能工作，但可能导致行为不
稳定。如果违例严重，需要精简设计或提高优化等级。

---

## 3.6 补充 flash 启动属性

> **这一步是本方案特有的，上游 Coyote 没有对应内容。**

Coyote 只面向 JTAG。它的 U250 约束文件除了压缩之外什么都没设置：

```bash
cat ~/fpga/Coyote/hw/constraints/u250/static/impl/u250_static_base.xdc
# set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design];
```

没有 `CONFIG_MODE`，没有 `SPI_BUSWIDTH`，没有 `CONFIGFALLBACK`。这样生成的 bitstream 如果写进
flash，会以最慢的 x1 位宽加载 —— 甚至可能根本来不及被枚举。

有意思的是，Coyote 自己的legacy U200 文件
（`hw/constraints/LEGACY/u200/u200_base.xdc`）里有**完整的 QSPI 属性，但全被注释掉了**。本步骤
实现的正是那段被注释的模板。

执行：

```bash
cd <本文档目录>/scripts

vivado -mode batch -source 30_gen_flash_image.tcl \
       -tclargs ~/fpga/Coyote/examples/01_hello_world/hw/build_hw
```

脚本会重新打开 `checkpoints/shell_routed.dcp`，施加 U250 的 flash 属性，然后输出 bitstream 和
MCS 文件对。**它不修改 Coyote 源码树**，所以 Coyote 仍可正常 `git pull` 升级。耗时 10–20 分钟。

### 施加的属性

```tcl
set_property CONFIG_MODE                     SPIx8       [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH   8           [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR YES         [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE  YES         [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE     63.8        [current_design]
set_property BITSTREAM.CONFIG.CONFIGFALLBACK Enable      [current_design]
set_property BITSTREAM.CONFIG.TIMER_CFG      0x0001FFFF  [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN      Pullup      [current_design]
set_property CONFIG_VOLTAGE                  1.8         [current_design]
set_property CFGBVS                          GND         [current_design]
```

每一条的作用：

| 属性 | 作用 |
|---|---|
| `CONFIG_MODE SPIx8` | U250 上是两颗 MT25QU01G 组成 dual Quad-SPI（x8） |
| `SPI_BUSWIDTH 8` | 必须与 `CONFIG_MODE` 一致，否则 FPGA 会用错误位宽去读 |
| `SPI_32BIT_ADDR YES` | 1 Gb 器件超出 24 位寻址能力 |
| `SPI_FALL_EDGE YES` | 主SPI 模式的采样边沿 |
| `CONFIGRATE 63.8` | 加载时钟。更快意味着在温度变化下更不可靠 |
| `CONFIGFALLBACK Enable` | **防砖**：CRC 校验失败时回落到 golden 镜像 |
| `TIMER_CFG` | 支撑上述回落机制的看门狗 |
| `CONFIG_VOLTAGE 1.8` / `CFGBVS GND` | U250 配置 bank 的电气参数 |

### 产物

```bash
ls -lh ~/fpga/Coyote/examples/01_hello_world/hw/build_hw/flash/
```

| 文件 | 用途 |
|---|---|
| `cyt_top_flash.bit` | 带 flash 启动设置的 bitstream |
| `coyote_u250_primary.mcs` | 第一颗 flash 器件 |
| `coyote_u250_secondary.mcs` | 第二颗 flash 器件 |

**出现两个 MCS 文件是正常的。** `write_cfgmem -interface SPIx8` 会把数据流拆分到两颗器件上，
而这正好是 `xbflash2 --dual-flash` 需要的文件对。

### flash 布局

```
0x00000000  出厂 golden 镜像   <- 永不写入
0x01002000  用户镜像           <- 我们的目标
```

`0x01002000` 不是随便定的。XRT 把它硬编码为：

```c
// XRT src/runtime_src/core/pcie/tools/xbflash.qspi/xspi.cpp
const unsigned int dftBitstreamGuardAddress = 0x01002000;
```

因为地址非0，`xbflash2` 会自动启用 bitstream guard：

```c
// 同一文件
if (bitstream_start_loc != 0) {
    if (!writeBitstreamGuard(bitstream_start_loc)) { ... }
    // "Enabled bitstream guard. Bitstream will not be loaded until flashing is finished."
}
```

因此烧写中断会留下守卫，板卡启动 golden 镜像。

### 未验证的参数（重要）

`-size 128` 和 `-interface SPIx8` 取自 AMD UG1289，且与 XRT 的双 MCS 接口相互印证，但
**没有在硬件上实际执行过**。如果 `write_cfgmem` 报错，用下面的方法核对：

```bash
vivado -mode tcl
# 然后执行：
get_cfgmem_parts *mt25qu01g*
report_property [lindex [get_cfgmem_parts *mt25qu01g*] 0]
```

再对照你板卡版本对应的 UG1289。常见的替代值是 `-size 256` 或 `-interface SPIx4`。
如果你发现了正确参数，请回来修正本文档。

---

## 验收标准

- [ ] `bitstreams/cyt_top.bit` 存在
- [ ] `bitgen.log` 中没有严重时序违例
- [ ] `flash/cyt_top_flash.bit` 存在
- [ ] `flash/coyote_u250_primary.mcs` 和 `_secondary.mcs` 都存在
- [ ] TCL 日志显示 `CONFIG_MODE = SPIx8` 且 `CONFIGFALLBACK = Enable`

**继续之前请备份这两个 MCS 文件** —— 重新生成要花几小时。

下一步：[05-flash-over-pcie.md](05-flash-over-pcie.md) —— 唯一有风险的阶段。
