# 在 Alveo U250 上部署 Coyote

在 AMD Alveo U250 上部署 [Coyote](https://github.com/fpgasystems/Coyote)（苏黎世联邦
理工的 FPGA shell），**全程不需要 JTAG 线** —— 整个流程可以通过 SSH 远程完成。

Coyote 官方流程要求用 JTAG 线烧写第一个 bitstream（必须去机房接线）。本方案改用
`xbflash2`（来自 AMD 的 XRT）通过 PCIe 写入板载 flash，绕开了这个限制。

---

## 文档索引

按顺序阅读即可完成部署。文件名前缀就是阶段号。

| 文档 | 阶段 | 耗时 | 碰硬件 |
|---|---|---|---|
| [00-overview.md](00-overview.md) | 概念、前置条件、风险 | — | — |
| [01-host-preparation.md](01-host-preparation.md) | 环境审计、依赖、hugepages | 10 分钟 | 否 |
| [02-vivado-install.md](02-vivado-install.md) | Vivado 2022.1 安装与 license | 2–4 小时 | 否 |
| [03-build-software.md](03-build-software.md) | 驱动、运行时、`xbflash2`、flash 探测 | 5 分钟 | 否 |
| [04-build-hardware.md](04-build-hardware.md) | 综合、flash 启动属性、MCS | 3–6 小时 | 否 |
| [05-flash-over-pcie.md](05-flash-over-pcie.md) | **PCIe 烧写、冷启动** | 30 分钟 | 是 |
| [06-runtime-verify.md](06-runtime-verify.md) | 加载驱动、跑通示例 | 15 分钟 | 是 |
| [99-troubleshooting.md](99-troubleshooting.md) | 按阶段的故障排查 | — | — |

阶段 0–3 完全不碰硬件。阶段 4 是唯一有风险的步骤，但有三重保护：bitstream guard、
硬件级 CRC 回落、以及一条命令恢复出厂镜像。

**没有 FPGA 基础？** 请先读
[概念铺垫一节](00-overview.md#先读这一节fpga-基础概念)，
它解释了什么是 bitstream、什么是 JTAG，以及为什么烧写 flash 能绕开 JTAG。

---

## 脚本索引

[`scripts/`](scripts/) —— 每个脚本都是幂等的，并且会校验输入参数。

| 脚本 | 用途 | 需要 root |
|---|---|---|
| [`00_check_env.sh`](scripts/00_check_env.sh) | 只读的环境就绪度审计 | 否 |
| [`10_setup_host.sh`](scripts/10_setup_host.sh) | 安装依赖包、预留 hugepages | 是 |
| [`11_fix_xilinx_downloads.py`](scripts/11_fix_xilinx_downloads.py) | 修复 Vivado 安装器 checksum 失败的文件 | 否 |
| [`12_xilinx_auth_token.py`](scripts/12_xilinx_auth_token.py) | 自动生成 Xilinx 认证 token | 否 |
| [`13_install_vivado_auto.sh`](scripts/13_install_vivado_auto.sh) | 自动循环安装 Vivado（安装 → 修复 → 重试） | 否 |
| [`20_build_xbflash2.sh`](scripts/20_build_xbflash2.sh) | 从 XRT 源码编译烧写工具 | 否 |
| [`21_probe_flash.py`](scripts/21_probe_flash.py) | 只读的 flash 控制器可达性探测 | 是 |
| [`30_gen_flash_image.tcl`](scripts/30_gen_flash_image.tcl) | 补充 flash 启动属性，生成 `.bit` + MCS | 否 |
| [`40_flash_over_pcie.sh`](scripts/40_flash_over_pcie.sh) | 经 PCIe 烧写 flash | 是 |
| [`50_load_driver.sh`](scripts/50_load_driver.sh) | 插入驱动，验证 probe | 是 |

> 脚本内部的注释和输出信息保持英文，以便在不同 locale 的终端下都能正常显示，也方便
> 直接复制到 issue 里提问。文档正文用中文。

---

## 本文档遵循的约定

- **始终标明验证状态。** 已在真实硬件上确认的步骤会明确标注；未实际执行过的步骤标为
  「未验证」。**请不要把后者当成已确认的事实。**
- **每个阶段结尾都有验收标准** —— 一份 checklist，确认后再进入下一阶段。
- **结论给出处。** 凡是依赖上游代码行为的判断，都会指明具体文件和代码位置，你可以
  自己核实，而不必相信文字描述。
