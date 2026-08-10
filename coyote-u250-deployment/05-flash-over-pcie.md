# 阶段 4 —— PCIe 烧写与冷启动

**耗时：** 约 30 分钟 · **是否碰硬件：** 是 · **风险：这是整个部署唯一有风险的阶段**

通过 PCIe 把 Coyote 镜像写进U250 的板载 flash，替代 Coyote 官方流程里的 JTAG 步骤。

---

## 4.1 开始之前先理解风险

### 实际写入的位置

```
flash 偏移              内容本阶段的操作
----------              ----------------
0x00000000              AMD 出厂 golden 镜像        不动
0x01002000              用户镜像                    覆盖
```

只写用户区。golden 镜像 —— 你的恢复退路 —— 不会被触碰。

### 三重保护

1. **bitstream guard。** 因为目标偏移非 0，`xbflash2` 会在烧写前写入守卫标记，仅在成功后清除。
   烧写中断则守卫仍在，FPGA 下次冷启动会加载 golden。摘自 XRT 的 `xspi.cpp`：

   ```c
   if (bitstream_start_loc != 0) {
       if (!writeBitstreamGuard(bitstream_start_loc)) { return -EINVAL; }
       // "Enabled bitstream guard. Bitstream will not be loaded until flashing is finished."
   }
   ...
   if (bitstream_start_loc != 0) {
       if (!clearBitstreamGuard(bitstream_start_loc)) { return -EINVAL; }
       // "Cleared bitstream guard. Bitstream now active."
   }
   ```

2. **硬件级回落。** bitstream 里的 `CONFIGFALLBACK Enable` 意味着 CRC 校验失败时，FPGA 会自己
   去加载 golden 镜像，不需要软件干预。

3. **显式恢复。** `xbflash2 program --spi --revert-to-golden` 一条命令恢复出厂状态。

### 仍然可能出问题的情形

| 情形 | 后果 | 恢复方式 |
|---|---|---|
| 烧写被中断 | 守卫仍在| 冷启动 → golden；重试 |
| 写入了坏镜像 | 加载时 CRC 失败 | 自动回落 golden |
| FPGA 加载太慢，来不及枚举 | 重启后看不到卡 | PCIe 重扫描，或恢复出厂 |
| golden 区被损坏 | **需要 JTAG** | 极不可能；本流程从不写该区域 |

只有最后一种情况需要物理接触，而本流程根本不会去写 golden 区。

### 前置检查

以下条件不全部满足，请不要继续：

- [ ] `21_probe_flash.py` 报告 **PASS**
- [ ] `coyote_u250_primary.mcs` 和 `_secondary.mcs` 存在，且**已备份**
- [ ] 你有冷启动手段（IPMI，或能到现场）
- [ ] 你接受当前 flash 内容被替换
- [ ] 没有其他人正在使用这台机器

---

## 4.2 记录当前状态

出问题时你会需要这些信息。

```bash
BDF=$(lspci -Dn -d 10ee: | awk '{print $1}' | head -1)
echo "BDF: $BDF"

sudo lspci -vvv -s "${BDF#0000:}" | tee ~/u250_before_flash.txt
cat /sys/bus/pci/devices/$BDF/device        # 期望 0xd004
```

把 `~/u250_before_flash.txt` 拷到这台机器之外保存。

---

## 4.3 烧写

```bash
cd <本文档目录>/scripts

sudo ./40_flash_over_pcie.sh \
    --mcs-stem ~/fpga/Coyote/examples/01_hello_world/hw/build_hw/flash/coyote_u250
```

脚本会依次：

1. 解析目标设备（也可用 `--device BDF` 指定）。
2. 卸载已加载的 `coyote_driver`、`xocl`、`xclmgmt`、`ami`，让 DMA 引擎干净停止。
3. 打开设备的内存空间解码。
4. 校验两个 MCS 文件存在，并确认镜像**不是**从偏移 0 开始。
5. 要求确认。
6. 调用 `xbflash2 program --spi --dual-flash --image<primary> --image <secondary>`。

**不要中断它。** 预计几分钟：工具要擦除扇区、写入、然后校验。

预期的结尾输出：

```
Enabled bitstream guard. Bitstream will not be loaded until flashing is finished.
Preparing flash chip 0
...
Cleared bitstream guard. Bitstream now active.

== FLASH SUCCEEDED ==
```

如果失败，脚本会打印恢复步骤。板卡仍然可以通过 golden 启动。

---

## 4.4 冷启动 —— 必须做

镜像已经在 flash 里，但**还没有生效**。FPGA 只在上电瞬间读取配置。

> **热重启（`reboot`）不够。** 它不会切断板卡供电，FPGA 会继续跑当前配置。**必须完全断电。**

远程方式，通过 BMC：

```bash
sudo ipmitool chassis power cycle
```

备选方案，按推荐程度排序：

```bash
sudo ipmitool chassis power off && sleep 15 && sudo ipmitool chassis power on
```

或者物理操作：关机，在电源处断电约 15 秒，再上电。

之后等待主机启动。大内存服务器的 POST 可能需要几分钟。

---

## 4.5 验证板卡是否变成 Coyote

```bash
lspci -Dn -d 10ee:
```

| 结果 | 含义 | 下一步 |
|---|---|---|
| `10ee:903f` | **成功** —— Coyote 已运行 | [06-runtime-verify.md](06-runtime-verify.md) |
| `10ee:d004` | FPGA 回落到了 golden | 见 4.6 |
| 什么都没有 | FPGA 未配置成功，或错过了枚举 | 见 4.7 |

检查链路：

```bash
BDF=$(lspci -Dn -d 10ee: | awk '{print $1}' | head -1)
cat /sys/bus/pci/devices/$BDF/current_link_speed
cat /sys/bus/pci/devices/$BDF/current_link_width
```

U250 上的 Coyote 应该协商为 Gen3 x16。位宽或速率偏低说明配置有问题。

再确认 MSI-X 存在 —— Coyote 需要它，而出厂镜像没有：

```bash
sudo lspci -vv -s "${BDF#0000:}" | grep -i "MSI-X"
```

能看到 `MSI-X: Enable- Count=...` 是 Coyote bitstream 确实加载成功的有力证据。

---

## 4.6 如果板卡仍显示 `0xd004`

FPGA 加载了 golden 而不是我们的镜像。按可能性排序：

**用户镜像 CRC 校验失败。** `CONFIGFALLBACK` 起作用了。重新烧写；如果再次失败，说明 MCS 文件
对很可能有问题（见
[04-build-hardware.md](04-build-hardware.md#未验证的参数重要)）。

**位宽或寻址模式不对。** 检查 TCL 日志里是否为 `CONFIG_MODE = SPIx8` 和
`SPI_32BIT_ADDR = YES`。与物理 flash 接线不匹配会让 FPGA 读到乱码。

**镜像没有落在 `0x01002000`。** 检查开头几条记录：

```bash
head -3 ~/fpga/.../flash/coyote_u250_primary.mcs
```

如果 MCS 从 0 开始，它会覆盖 golden —— 脚本有防护，但还是核实一下。

---

## 4.7 如果板卡完全消失

先尝试重扫描，它可以在不断电的情况下重新枚举：

```bash
echo 1 | sudo tee /sys/bus/pci/rescan
lspci -Dn -d 10ee:
```

**重扫描后出现了** —— 说明 FPGA 配置正确，但完成时间**晚于** BIOS 枚举，即
[00-overview.md](00-overview.md#已知风险) 里描述的时序风险。应对：

- 延长 POST（开启完整内存训练、关闭快速启动），给 FPGA 更多时间。
- 降低 `CONFIGRATE`，或确认 x8 位宽确实生效，以加快加载。
- 作为权宜之计，把重扫描做成开机服务。

**重扫描后仍然没有** —— 恢复出厂：

```bash
sudo ./40_flash_over_pcie.sh --revert-to-golden --device 0000:1a:00.0
sudo ipmitool chassis power cycle
```

如果连板卡都看不到，`xbflash2` 没有通信对象，此时只能用 JTAG。这需要 golden 区被损坏才会发生，
而本流程从不写该区域。

---

## 验收标准

- [ ] `40_flash_over_pcie.sh` 输出了 `FLASH SUCCEEDED`
- [ ] 已执行**冷**启动
- [ ] `lspci -Dn -d 10ee:` 显示 `10ee:903f`
- [ ] 链路为 Gen3 x16
- [ ] MSI-X capability 存在

下一步：[06-runtime-verify.md](06-runtime-verify.md)
