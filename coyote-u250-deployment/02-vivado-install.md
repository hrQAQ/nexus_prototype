# 阶段 1 —— 安装 Vivado 2022.1

**耗时：** 2–4 小时（主要是下载） · **是否碰硬件：** 否 · **风险：** 无

> **版本没有商量余地：必须 2022.1。** 理由见
> [00-overview.md](00-overview.md#vivado-版本约束重要)。简单说：Coyote 预编译的 U250 静态层
> checkpoint 是 Vivado v2022.1.2 生成的，且是锁定的 DFX checkpoint。AMD 要求 DFX 流程全链路
> 使用同一版本。用新版会强制重建静态层，多花 10–15 小时。

---

## 1.1 自己确认需要哪个版本

不要轻信任何关于版本的说法 —— 直接从 checkpoint 里读：

```bash
cd ~/fpga/Coyote/hw/checkpoints
unzip -p static_routed_locked_u250.dcp dcp.xml | grep -E "PRODUCT|Part|HDBlackbox"
```

预期输出：

```xml
<PRODUCT Name="Vivado v2022.1.2 (64-bit)"/>
<Part Name="xcu250-figd2104-2L-e"/>
<HDBlackboxInfo Name="inst_shell HD.RECONFIGURABLE"/>
```

`.dcp` 本质上就是个 zip 包，所以这一步不需要任何 Xilinx 工具。如果你的仓库版本显示的是别的
Vivado 版本，那就装**那个**版本。

---

## 1.2 下载安装包

需要一个免费的 AMD 账号。

1. 打开归档下载页：
   <https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/vivado-design-tools/archive.html>
2. 版本选 **2022.1**。
3. 下载 **"Xilinx Unified Installer 2022.1: Linux Self Extracting Web Installer"**
   —— 约 300 MB，文件名形如 `Xilinx_Unified_2022.1_0420_0327_Lin64.bin`。

> **不要**下载那个约 74 GB 的 "All OS installer Single-File Download"，除非你确实需要离线
> 安装包。Web 版安装器只会下载你勾选的组件。

校验一下文件完整性：

```bash
ls -l Xilinx_Unified_2022.1_0420_0327_Lin64.bin
file Xilinx_Unified_2022.1_0420_0327_Lin64.bin
# 应显示: POSIX shell script executable (binary data)
```

---

## 1.3 Ubuntu 22.04 兼容性处理

Vivado 2022.1 官方只支持到 Ubuntu 20.04。它在 22.04 / 24.04 上能跑，但安装器需要几个库：

```bash
sudo apt-get install -y \
    libncurses5 libncurses5-dev libtinfo5 \
    libx11-6 libxrender1 libxtst6 libxi6 \
    libfreetype6 libfontconfig1 \
    ocl-icd-opencl-dev \
    libstdc++6 lsb-release
```

**`libtinfo5` 是这里最常见的坑。** 在 24.04 上如果装不上，可以临时添加 jammy 源，或者直接下载
对应的 `.deb` 安装。

给安装器设置 C 语言环境，否则它解析非英文输出会出错：

```bash
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
```

---

## 1.4 批量模式安装

图形界面安装会默认勾选远超需要的组件。用批量模式配合配置文件，可以把体积从约 250 GB 压到约
120 GB。

### 解压安装器

```bash
cd <安装包所在目录>
chmod +x Xilinx_Unified_2022.1_0420_0327_Lin64.bin

# 只解压不运行，以便直接调用 xsetup
./Xilinx_Unified_2022.1_0420_0327_Lin64.bin --noexec --target /tmp/xlnx_installer
cd /tmp/xlnx_installer
```

解压时会打印 `Verifying archive integrity... All good.`，这同时验证了安装包没有损坏。

### 生成配置模板

```bash
printf '2\n1\n' | ./xsetup -b ConfigGen
```

两个输入的含义：`2` = Vivado，`1` = Vivado ML Standard（免费版）。生成的模板位于
`~/.Xilinx/install_config.txt`。

> 直接跑 `./xsetup -b ConfigGen` 会进入交互式菜单等待输入。用 `printf` 管道喂进去可以在脚本
> 里自动完成。

### 裁剪配置

模板默认勾选了全部器件系列。新建一份精简配置：

```bash
cp ~/.Xilinx/install_config.txt ~/.Xilinx/install_config_coyote_u250.txt
```

编辑 `~/.Xilinx/install_config_coyote_u250.txt`，把 `Modules` 和快捷方式相关的行改成：

```ini
Edition=Vivado ML Standard
Product=Vivado
Destination=/tools/Xilinx

# 只保留 Virtex UltraScale+（U250 所属系列）
Modules=Virtex UltraScale+:1,Virtex UltraScale+ HBM:0,Virtex UltraScale+ 58G:0,Kintex UltraScale:0,Kintex UltraScale+:0,Artix UltraScale+:0,Spartan-7:0,Artix-7:0,Kintex-7:0,Zynq-7000:0,Zynq UltraScale+ MPSoC:0,Install Devices for Kria SOMs and Starter Kits:0,Vitis Model Composer(Xilinx Toolbox for MATLAB and Simulink. Includes the functionality of System Generator for DSP):0,DocNav:0

InstallOptions=

CreateProgramGroupShortcuts=0
CreateShortcutsForAllUsers=0
CreateDesktopShortcuts=0
CreateFileAssociation=0
EnableDiskUsageOptimization=1
```

裁剪依据：

| 组件 | 取舍 | 原因 |
|---|---|---|
| **Virtex UltraScale+** | **保留** | U250 的芯片`xcu250-figd2104-2L-e` 属于这个系列，**必需** |
| Vitis HLS | 自动包含 | Vivado ML Standard 自带；Coyote 的构建流程会调用它（见 `cmake/FindVitisHLS.cmake`），即使是纯 RTL 示例 |
| 7 系列 / Zynq / Kintex / Spartan / Artix / Kria | 关闭 | 与本项目无关，关掉省约 100 GB |
| Vitis Model Composer | 关闭 | 依赖 MATLAB，用不上 |
| DocNav | 关闭 | 无图形界面的服务器上没用 |
| Install Cable Drivers | 不选 | **JTAG 线缆驱动**。本方案就是为了绕开 JTAG，不需要 |

> `Modules` 必须写成**一行**，条目之间用逗号分隔，不能换行。

### 生成认证 token（必须，否则下载会直接失败）

**这一步很容易被漏掉。** 批量安装在开始下载之前，要求先有一个认证 token，否则会立刻报错退出：

```
ERROR - Before being able to download and install you must generate an
        authentication token using the xsetup -b AuthTokenGen command.
```

手动方式（会交互询问账号密码）：

```bash
cd /tmp/xlnx_installer
./xsetup -b AuthTokenGen
#依次输入 AMD账号邮箱、密码
```

自动化方式，用本仓库的脚本（适合无人值守）：

```bash
export XILINX_USER='you@example.com'
read -rs XILINX_PASS && export XILINX_PASS# 输入时不回显

cd <本文档目录>/scripts
./12_xilinx_auth_token.py --installer /tmp/xlnx_installer

unset XILINX_PASS                # 用完立刻清除
```

关于 token：

| 项 | 说明 |
|---|---|
| 保存位置 | `~/.Xilinx/wi_authentication_key` |
| 权限 | `0400`，仅本人可读 |
| 有效期 | **约 7 天**，过期后重新生成即可 |
| 幂等性 | 脚本检测到有效 token 会直接退出；加 `--force` 强制刷新 |

> **安全约定：密码只从环境变量读取。** 脚本不接受命令行传密码，因为命令行参数对
> 系统上任何用户的 `ps` 都是可见的。密码不落盘、不写日志，脚本输出里也会被替换成掩码。
> 用完记得 `unset XILINX_PASS`。

### 执行安装

```bash
sudo mkdir -p /tools/Xilinx
sudo chown -R "$USER:$USER" /tools/Xilinx
```

安装耗时很长，**务必放进 `screen` 或 `tmux`**，否则 SSH 断开会中断安装：

```bash
screen -S vivado_install

export LANG=C.UTF-8 LC_ALL=C.UTF-8
cd /tmp/xlnx_installer
./xsetup \
    --agree XilinxEULA,3rdPartyEULA \
    --batch Install \
    --config ~/.Xilinx/install_config_coyote_u250.txt 2>&1 | tee ~/vivado_install.log

# Ctrl-A 然后按 D 脱离；用 screen -r vivado_install 重新接入
```

预计 1–3 小时，取决于网络带宽。另开一个终端看进度：

```bash
tail -f ~/vivado_install.log
```

> `--agree XilinxEULA,3rdPartyEULA` 是 2022.1 的正确参数。更老的版本还需要 `WebTalkTerms`。

### 下载报大量 "Checksum failed" 的处理

在跨境或高延迟链路上，很可能看到密集的校验失败，最终以退出码 3 收场：

```
ERROR - Checksum failed, expected: 150944a4... but was: 48ed6527... for file https://...
ERROR - There was an error downloading file: ... error was: <html>The downloaded archive is corrupted
ERROR - The installation failed.
```

**这不是网络坏了，也不是文件被篡改。** 判定依据：把同一个 URL 用单线程 `curl` 重新下载，
md5 与期望值完全一致。损坏的文件本身也是**合法的 xz 归档**（`file` 能正常识别），只是内容
属于另一个文件 —— 典型的并发下载响应错配，问题出在安装器自带的多线程下载器。

用本仓库脚本修复：

```bash
cd <本文档目录>/scripts

# 先看要做什么，不实际下载
./11_fix_xilinx_downloads.py \
    --log ~/vivado_install.log \
    --payload /tools/Xilinx/Downloads/Vivado_2022.1/payload \
    --dry-run

# 实际修复
./11_fix_xilinx_downloads.py \
    --log ~/vivado_install.log \
    --payload /tools/Xilinx/Downloads/Vivado_2022.1/payload
```

脚本的工作方式：从安装器日志里解析每个失败文件的 URL 和期望 md5，用
`curl --no-keepalive --http1.1` 单线程重新下载（禁用连接复用即可规避错配），校验 md5 通过后
才替换到 payload 目录。

### 推荐做法：自动循环安装（无人值守）

由于每轮安装器只暴露当轮失败的文件，手工「跑 → 修 → 再跑」可能要重复很多次。本仓库提供了
把这个循环自动化的脚本：

```bash
cd<本文档目录>/scripts

# 先做前置检查，不实际安装
./13_install_vivado_auto.sh --dry-run

# 放进 screen 跑，然后就可以不管了
screen -dmS vivado ./13_install_vivado_auto.sh
screen -r vivado                       # 查看进度，Ctrl-A 再按 D 脱离
```

每一轮的动作：

1. 确认认证 token 有效（失效则按需重新生成）
2. 运行安装器
3. 成功 → 退出
4. 失败 → 解析日志，单线程重新下载校验失败的文件
5. 若本轮没修好任何文件（无进展）→ 停止并说明原因

它会区分失败类型，不在不可恢复的错误上空转：

| 失败类型 | 处理 |
|---|---|
| token 失效 | 删除旧 token，下一轮重新生成 |
| checksum 失败 | 调用修复脚本，然后重试 |
| 其他错误 | **立即停止**并打印日志中的 ERROR 行|
| 修复了 0 个文件 | **立即停止**（说明链接过期或网络不通） |

配合环境变量可以实现完全无人值守（含 token 自动刷新）：

```bash
export XILINX_USER='you@example.com'
read -rs XILINX_PASS && export XILINX_PASS

screen -dmS vivado ./13_install_vivado_auto.sh --auto-token

unset XILINX_PASS
```

其他选项：`--max-rounds N`（默认 20）、`--installer DIR`、`--config FILE`、`--log FILE`。
每轮的日志会单独存为 `~/vivado_install.roundN.log`，便于事后追溯。

### 手工循环（等价做法）

如果你想自己控制每一步：

```bash
cd <本文档目录>/scripts

# 1. 修复上一轮的坏文件
./11_fix_xilinx_downloads.py \
    --log ~/vivado_install.log \
    --payload /tools/Xilinx/Downloads/Vivado_2022.1/payload

# 2. 重跑安装器，它会跳过已校验通过的文件
cd /tmp/xlnx_installer
./xsetup --agree XilinxEULA,3rdPartyEULA --batch Install \
         --config ~/.Xilinx/install_config_coyote_u250.txt 2>&1 | tee -a ~/vivado_install.log

# 3. 若仍失败，回到第 1 步
```

注意两点：

- 日志里的下载 URL 带`expires` 参数（有效期约 8 小时）。如果修复脚本报下载失败，先重跑一次
  安装器拿到新链接，再执行修复。
- 日志**只记录失败的文件**，不是完整清单，所以无法据此离线下载全部 payload。

> **如果所在网络下这个问题反复出现**，更省事的办法是直接下载约 74 GB 的离线完整包
> （"All OS installer Single-File Download"）。它是单个文件，可以用 `wget -c` 断点续传，
> 自带校验，不依赖安装器的下载器。代价是磁盘占用更大。


---

## 1.5 配置环境变量

```bash
source /tools/Xilinx/Vivado/2022.1/settings64.sh
vivado -version
```

预期输出 `Vivado v2022.1.2 (64-bit)` —— 与生成 checkpoint 的版本一致。

写进 shell 配置：

```bash
echo 'source /tools/Xilinx/Vivado/2022.1/settings64.sh' >> ~/.bashrc
```

确认 Vitis HLS 存在（Coyote 的 CMake 会找它）：

```bash
which vitis_hls
```

---

## 1.6 安装 license

只有用到收费 IP 时才需要。普通 Vivado ML Standard 安装已经足够跑示例 1–8 和 10。

```bash
mkdir -p ~/.Xilinx
cp /path/to/Xilinx.lic ~/.Xilinx/
export XILINXD_LICENSE_FILE=$HOME/.Xilinx/Xilinx.lic
echo 'export XILINXD_LICENSE_FILE=$HOME/.Xilinx/Xilinx.lic' >> ~/.bashrc
```

### 节点锁定 license 绑定MAC 地址

检查绑定的是不是本机：

```bash
grep -o "HOSTID=[0-9a-f]*" ~/.Xilinx/Xilinx.lic | head -1
for i in /sys/class/net/*; do
    echo "$(basename "$i"): $(tr -d ':' < "$i/address" 2>/dev/null)"
done
```

`HOSTID` 必须等于某个网卡MAC 去掉冒号后的值。**为另一台机器签发的 license 无法使用**——
这是换机器时唯一不能直接搬过去的东西。

### 查看有哪些 feature

```bash
grep -o "INCREMENT [a-zA-Z0-9_]*" ~/.Xilinx/Xilinx.lic | sort -u
```

| Feature | 用途 |
|---|---|
| `cmac_usplus` | 100G 以太网 —— **Coyote 示例 9 和 11 必需** |
| `ernic` / `etrnic` | 嵌入式 RDMA NIC —— **不是** Coyote 网络栈用的东西 |
| 以上都没有 | 只能跑示例 1–8 和 10 |

> **`ernic`/`etrnic` 不能替代 `cmac_usplus`。** Coyote 的网络栈基于 UltraScale+ Integrated
> 100G Ethernet Subsystem，需要 `cmac_usplus`。没有它就保持 `EN_NET=0`，只跑非网络示例。

---

## 1.7 验收

```bash
cd <本文档目录>/scripts
./00_check_env.sh
```

Vivado 那一项现在应该通过，并显示 2022.1。

---

## 验收标准

- [ ] token 已生成（`~/.Xilinx/wi_authentication_key`存在）
- [ ] `vivado -version` 显示 v2022.1.2
- [ ] `which vitis_hls` 能找到
- [ ] checkpoint 版本与已安装 Vivado 一致
- [ ] `XILINXD_LICENSE_FILE` 已设置（如需收费 IP）
- [ ] license 的 `HOSTID` 与本机某个 MAC 匹配
- [ ] `00_check_env.sh` 全部通过

下一步：[03-build-software.md](03-build-software.md)
