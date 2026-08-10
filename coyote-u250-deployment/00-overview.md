# Coyote on Alveo U250 —— 部署指南

在 AMD Alveo U250 上部署 [Coyote](https://github.com/fpgasystems/Coyote)（苏黎世联邦理工的
FPGA shell），**全程不需要 JTAG 线**。

Coyote 官方流程要求用JTAG 线烧写第一个 bitstream，这意味着必须去机房接线。本方案改用
PCIe 写入板载flash，因此整个部署可以通过 SSH 远程完成。

---

## 先读这一节：FPGA 基础概念

如果你没接触过 FPGA，这几个概念是理解全文的前提。

**FPGA** —— 一块「内部连线可以反复重新编程」的芯片。CPU 的电路在出厂时就固定了，你只能给它
送指令；而 FPGA 是你描述一个电路，它就**变成**那个电路。

**bitstream（比特流）** —— 描述「芯片内部怎么连线」的二进制文件，扩展名 `.bit`。它相当于
FPGA 的可执行文件。

**Vivado** —— AMD 官方工具链，负责把硬件描述代码编译成 bitstream。这个过程叫**综合 + 布局
布线**，很慢：本项目预计 3–6 小时。

**Coyote** —— 一个「FPGA 操作系统」。它已经实现了 PCIe 通信、DMA、虚拟内存、网络栈这些基础
设施，你只需要写自己的加速逻辑。它把设计分成三层：

| 层 | 内容 | 谁来构建 |
|---|---|---|
| 静态层 static | PCIe 与主机通信，永不改变 | Coyote 提供**预编译成品**（`static_routed_locked_u250.dcp`） |
| 动态层 shell | 内存控制器、网络栈等公共服务 | 你构建，每种配置一次 |
| 应用层 vFPGA | 你的加速器 | 你构建 |

**vFPGA** —— 「虚拟 FPGA」。类似虚拟机，一块物理 FPGA 可以切分成多个互相隔离的 vFPGA。

**JTAG** —— 一根**调试线**（板卡上一个 micro-USB 口），绕过 PCIe 直连芯片。通常首次烧写必须
用它。**本方案要避开的就是这个。**

---

## 为什么 PCIe 烧写这条路走得通

一个自然的疑问是：为什么不直接通过 PCIe 把 bitstream 推给FPGA？

因为 **PCIe 控制器本身就是 FPGA 内部的一块电路**。如果通过 PCIe 去重新配置整个 FPGA，配置一
开始，承载数据的 PCIe 电路就先被拆掉了—— 等于你正在锯自己坐着的那根树枝。这是物理死锁，任何
软件都绕不过去。

绕过它的办法是**板载 flash 芯片**。它是焊在卡上的独立器件，不在 FPGA 内部。每次板卡上电，
FPGA 都会从这颗 flash 读取配置，就像电脑开机从硬盘加载操作系统。

往 flash 写东西，不会干扰 FPGA 当前正在运行的电路。所以：

```
1. 通过 PCIe 把新设计写进 flash      （PCIe 链路全程不断）
2. 冷启动机器（完全断电重启）
3. FPGA 上电时从 flash 读到新设计
```

死锁解除—— 而这**正是 Alveo 卡出厂时预设的开箱方式**。

### 两种烧写方式的对比

| | Coyote 官方（JTAG） | 本方案（PCIe → flash） |
|---|---|---|
| 写到哪里 | FPGA 内部配置RAM | flash 芯片 |
| 断电后是否保留 | 不保留，恢复成flash 里的内容 | 保留 |
| 前提条件 | JTAG 线 + 物理接触 | 只需 PCIe，可完全远程 |
| 何时生效 | 立即（秒级） | 需冷启动 |
| 如何撤销 | 断电即撤销 | `--revert-to-golden` |

### 用到的工具

`xbflash2`，从 AMD 的 XRT 源码编译得到。AMD 自己的文档
（`src/runtime_src/doc/toc/xbflash2.rst`）这样描述它：

> "a standalone command line utility to flash a **custom image** onto given device"
> （独立的命令行工具，用于把**自定义镜像**烧写到指定设备）
> "This tool **doesn't require XRT Package**"（本工具**不需要 XRT 包**）
> "This tool is verified and supported only on **XDMA PCIe DMA designs**"
> （本工具仅在 **XDMA PCIe DMA 设计**上验证并支持）

Coyote 正是 XDMA 设计，所以这属于官方支持的场景。该工具通过 sysfs 把 BAR0 映射到用户空间来
访问 flash 控制器，因此不需要加载任何内核驱动。

### 为什么这样做是安全的

三重相互独立的保护：

1. **golden 镜像永不被写。** 全新的 U250 出厂时在 flash 偏移 `0x0` 处写有 AMD 的出厂镜像。
   我们的镜像写到**用户区** `0x01002000`。这个偏移不是猜的 —— XRT 在
   `xbflash.qspi/xspi.cpp` 里把它硬编码为 `dftBitstreamGuardAddress`。

2. **bitstream guard（比特流守卫）。** 因为目标偏移非0，`xbflash2` 会在烧写前写入一个守卫
   标记，只在成功后清除。烧写中断则守卫仍在，FPGA 下次冷启动会回落到 golden 镜像。

3. **一条命令恢复出厂。** `xbflash2 program --spi --revert-to-golden`。

此外我们在 bitstream 里开启了 `CONFIGFALLBACK`，用户区镜像损坏时**硬件层面**会自动回落到
golden。

---

## 前置条件

### 硬件

| 项| 要求 | 说明 |
|---|---|---|
| FPGA 卡 | Alveo **U250** | Coyote 也支持 U55C / U280 / V80，但本文的 flash 参数是 U250 专用的 |
| 卡的状态 | 出厂镜像（PCI id `10ee:d004`）或任意 XDMA 设计 | 全新卡最理想 |
| 主机 | x86_64，内存 ≥ 64 GB | 综合很吃内存 |
| 磁盘 | 剩余 ≥ 200 GB | Vivado 约 120 GB，构建树约 20 GB |
| BMC / IPMI | 建议有 | 用于远程冷启动；没有的话需要别的断电手段 |

### 软件

| 项 | 要求 |
|---|---|
| Linux | 内核 ≥ 5（已测试 5.4、5.15、6.2、6.8） |
| 发行版 | Ubuntu 20.04 / 22.04 / 24.04 |
| Vivado | **2022.1** —— 见下方版本说明 |
| CMake | ≥ 3.5，支持 C++17 |
| Secure Boot | **必须关闭**（驱动模块未签名） |
| BIOS | **必须开启 Above 4G Decoding**（Coyote 需要 64 位 BAR） |

### Vivado 版本约束（重要）

> **必须用 Vivado 2022.1。用新版会多花 10–15 小时。**

Coyote 附带了一份预布局布线并锁定的静态层 checkpoint。它的元数据
（`hw/checkpoints/static_routed_locked_u250.dcp` 内的 `dcp.xml`）写着：

```xml
<PRODUCT Name="Vivado v2022.1.2 (64-bit)"/>
<Part Name="xcu250-figd2104-2L-e"/>
<HDBlackboxInfo Name="inst_shell HD.RECONFIGURABLE"/>
```

`HD.RECONFIGURABLE` 标记说明这是动态功能重构（DFX）流程。AMD 在 UG909 中规定：**DFX 流程的
所有环节必须使用同一版本 Vivado**。用新版 Vivado 去链接 2022.1 生成的锁定 checkpoint 会直接
报版本错误。

用新版就必须加 `BUILD_STATIC=1` 重新生成静态层，多花 10–15 小时，而且经常需要改源码。

### License

Coyote 的网络配置会实例化 UltraScale+ Integrated 100G Ethernet Subsystem（CMAC），需要付费
的 `cmac_usplus` license feature。

- **示例 1–8 和 10**：普通 Vivado 安装即可，无需额外 license。
- **示例 9 和 11**（RDMA、抓包）：需要 `cmac_usplus`。

查看某个 license 文件包含哪些 feature：

```bash
grep -o "INCREMENT [a-zA-Z0-9_]*" /path/to/Xilinx.lic | sort -u
```

---

## 部署阶段

| # | 阶段 | 文档 | 耗时 | 是否碰硬件 |
|---|---|---|---|---|
| 0 | 环境检查与准备 | [01-host-preparation.md](01-host-preparation.md) | 10 分钟 | 否 |
| 1 | 安装 Vivado 2022.1 | [02-vivado-install.md](02-vivado-install.md) | 2–4 小时 | 否 |
| 2 | 编译驱动与软件 | [03-build-software.md](03-build-software.md) | 5 分钟 | 否 |
| 3 | 综合 bitstream | [04-build-hardware.md](04-build-hardware.md) | 3–6 小时 | 否 |
| 4 | PCIe 烧写 + 冷启动 | [05-flash-over-pcie.md](05-flash-over-pcie.md) | 30 分钟 | **是** |
| 5 | 加载驱动并验证 | [06-runtime-verify.md](06-runtime-verify.md) | 15 分钟 | **是** |
| — | 故障排查 | [99-troubleshooting.md](99-troubleshooting.md) | — | — |

阶段 0–3 完全不碰硬件，跑坏不了任何东西。**阶段 4 是唯一有风险的步骤。**

---

## 脚本

全部位于 [`scripts/`](scripts/)。每个脚本都是幂等的（可重复执行），并且会校验输入参数。

| 脚本 | 用途 | 需要 root |
|---|---|---|
| `00_check_env.sh` | 只读的环境就绪度审计 | 否 |
| `10_setup_host.sh` | 安装依赖包、预留 hugepages | 是 |
| `11_fix_xilinx_downloads.py` | 修复 Vivado 安装器 checksum 失败的文件 | 否 |
| `12_xilinx_auth_token.py` | 自动生成 Xilinx 认证 token | 否 |
| `13_install_vivado_auto.sh` | 自动循环安装 Vivado（安装→修复→重试） | 否 |
| `20_build_xbflash2.sh` | 从 XRT 源码编译烧写工具 | 否 |
| `21_probe_flash.py` | 只读的 flash 控制器可达性探测 | 是 |
| `30_gen_flash_image.tcl` | 补充 flash 启动属性，生成 `.bit` + MCS | 否 |
| `40_flash_over_pcie.sh` | 经 PCIe 烧写 flash（**风险步骤**） | 是 |
| `50_load_driver.sh` | 插入驱动，验证 `probe returning 0` | 是 |

---

## 命令速查

```bash
# 阶段 0
./scripts/00_check_env.sh
sudo ./scripts/10_setup_host.sh

# 阶段 2
cd Coyote/driver && make TARGET_PLATFORM=ultrascale_plus
cd Coyote/examples/01_hello_world/sw && mkdir -p build_sw && cd build_sw && cmake ../ && make

# 阶段 3
cd Coyote/examples/01_hello_world/hw && mkdir -p build_hw && cd build_hw
cmake ../ -DFDEV_NAME=u250 && make project && make bitgen

# 阶段 4
./scripts/20_build_xbflash2.sh --xrt-src /path/to/XRT/src
sudo ./scripts/21_probe_flash.py
vivado -mode batch -source scripts/30_gen_flash_image.tcl -tclargs <build_hw>
sudo ./scripts/40_flash_over_pcie.sh --mcs-stem <build_hw>/flash/coyote_u250
sudo ipmitool chassis power cycle     # 冷启动，必须做

# 阶段 5
lspci -Dn -d 10ee:                    # 期望看到 0x903f
sudo ./scripts/50_load_driver.sh --driver Coyote/driver/build/coyote_driver.ko
cd Coyote/examples/01_hello_world/sw/build_sw && ./test
```

---

## 验证状态

本文档明确区分「已在真实硬件上验证」和「尚未验证」的内容。**请不要把未验证的步骤当成已确认
的事实。**

**已在硬件上验证**（Ubuntu 22.04，内核 6.8.0-110，Supermicro SYS-4029GP-TRT，
U250 位于 `0000:1a:00.0`）：

- `coyote_driver.ko` 可在 6.8 内核上编译通过
- Coyote C++ 库与示例 1 的 `test` 可编译通过
- `xbflash2` 可从 XRT 源码独立编译并运行
- AXI Quad SPI flash 控制器在 BAR0+`0x40000` 处经 PCIe 可达
  （`CR=0x180`、`SR=0xa5`，即 PG153 文档中的复位值）
- 确认该卡为出厂镜像：`0xd004` 在 XRT 的 `devices.h` 中对应 `XBB_MFG("u250")`
- hugepages 已预留并持久化
- `00_check_env.sh` 与 `21_probe_flash.py` 输出的判定正确

**尚未验证**（受阻于 Vivado 2022.1 尚未安装）：

- U250 的 bitstream 综合
- `30_gen_flash_image.tcl` 中 `write_cfgmem` 的具体参数，特别是 `-size 128` 和
  `-interface SPIx8`。这些取自 AMD UG1289，且与 XRT 的双 MCS 接口相互印证，但**没有实际执行
  过**。
- flash 烧写本身
- 冷启动后的 PCIe 重新枚举（见下方时序风险）
- 驱动绑定与端到端示例

### 已知风险

**PCIe 枚举时序竞争。** PCIe 规范要求设备在上电后 100 ms 内响应，而 U250 的完整 bitstream
从 SPI flash 加载需要数秒。在POST 时间较长的主机上（大内存服务器通常需要 60 秒以上），FPGA
会在枚举前早已加载完成；但在快速启动的主机上，可能来不及。缓解手段：PCIe 重扫描，或调整 BIOS
设置延长 POST。

**Coyote 本身不支持 flash 启动。** `hw/constraints/u250/**` 中没有任何 `CONFIG_MODE` 或
`SPI_BUSWIDTH` 设置，因为上游只支持 JTAG。如果不加 `30_gen_flash_image.tcl` 补充的那些属性，
FPGA 会以最慢的 x1 位宽加载，大幅加剧上述时序风险。**这是本方案唯一有意偏离上游 Coyote 的
地方。**

---

## 参考资料

- [Coyote](https://github.com/fpgasystems/Coyote) · [官方文档](https://fpgasystems.github.io/Coyote/)
- [XRT](https://github.com/Xilinx/XRT) —— `xbflash2` 的来源
- AMD UG1289 —— Alveo U200/U250 重构、MCS 生成
- AMD UG908 —— Vivado 编程与调试，`write_cfgmem`
- AMD UG909 —— 动态功能重构（DFX）
- Xilinx PG153 —— AXI Quad SPI IP
- Coyote v2 论文，SOSP '25，[doi:10.1145/3731569.3764845](https://doi.org/10.1145/3731569.3764845)
