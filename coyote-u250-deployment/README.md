# 在 Alveo U250 上部署 Coyote

在 AMD Alveo U250 上部署 [Coyote](https://github.com/fpgasystems/Coyote)（苏黎世联邦
理工的 FPGA shell），**全程不需要 JTAG 线** —— 整个流程可以通过 SSH 远程完成。

Coyote 官方流程要求用 JTAG 线烧写第一个 bitstream（必须去机房接线）。本方案改用
`xbflash2`（来自 AMD 的 XRT）通过 PCIe 写入板载 flash，绕开了这个限制。

---

## Quick Start（新机器一键落地）

> 面向场景：你已经在一台机器上跑通了这套流程，现在要在**第二台**装了 Alveo U250
> 的机器上复现，希望尽量少手动配置。

### 前置条件

- Ubuntu 20.04 / 22.04（本文所有阶段脚本都按apt 系写）
- 该机器能通过 SSH 访问 GitHub（用来clone 主仓，不需要写权限也行）
- 该机器能出网到 `gh-proxy.org`（用来拉上游Coyote 源码，见下）
- 目前网络中如果 `github.com` 本身也能直连，`gh-proxy` 会成为无损耗的加速兜底

### 一、克隆并初始化

```bash
# 1. 拿到本仓库（主仓走 SSH；如无 SSH key，可换成 https URL）
git clone git@github.com:hrQAQ/nexus_prototype.git
cd nexus_prototype

# 2. 拉取所有上游代码（Coyote 以及 Coyote 自己的嵌套 submodule）
#    该脚本会：
#      - 在【本仓库范围内】配置 gh-proxy insteadOf 规则（不污染 ~/.gitconfig）
#      - 递归初始化所有 submodule
#      - 打印锁定的 upstream commit
./scripts/bootstrap.sh

# 3. 校验：以下命令应输出 Coyote 的目录树
ls upstream/Coyote/hw upstream/Coyote/hw/services/network
```

如果这台机器直连 GitHub 更快，也可以跳过 gh-proxy：

```bash
NEXUS_USE_GH_PROXY=0 ./scripts/bootstrap.sh
```

> 结果：`upstream/Coyote/` 里就是**与第一台机器完全相同的** Coyote 源码
> —— submodule 用 commit SHA 锁定，两台机器上的 `git rev-parse HEAD` 输出一致。

### 二、按阶段文档走

**注意路径**：下方阶段文档（`03-build-software.md`、`04-build-hardware.md` 等）
写的都是 `~/fpga/Coyote/...`。这是首台机器上的历史约定。在新机器上有两种做法，
选一即可：

- **方案 A（推荐，零改动）**：建软链，让旧路径指向 submodule 里的 Coyote

  ```bash
  mkdir -p ~/fpga
  ln -s "$(pwd)/upstream/Coyote" ~/fpga/Coyote
  ls -l ~/fpga/Coyote     # 应该是软链
  ```

- **方案 B**：读文档时把每一处`~/fpga/Coyote` 心里替换成
  `<repo>/upstream/Coyote`，其他不变

然后按顺序执行阶段文档，见下方 [文档索引](#文档索引)。至少要完整过一遍
`01-host-preparation.md`（依赖、hugepages）和 `02-vivado-install.md`
（Vivado 2022.1）这两步 —— 它们是宿主机级的，两台机器都要各自做。

### 三、上游版本管理

-本仓库把 Coyote 锁定在 `upstream/Coyote` submodule 的一个具体 commit 上。
  想升级到上游 master的最新提交时：

  ```bash
  cd upstream/Coyote
  git fetch origin
  git checkout origin/master
  cd -
  git add upstream/Coyote
  git commit -m "bump: Coyote -> <new-sha>"
  git push
  ```

  然后另一台机器只需要 `git pull && git submodule update --init --recursive`
  就能同步到同一个 commit。

- **不要**在`upstream/Coyote/` 里直接改 Coyote 源码然后 commit —— 我们对
  Coyote 的所有增量都放在 `coyote-u250-deployment/scripts/` 里，保持 Coyote
  子模块干净可`git pull`。

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
