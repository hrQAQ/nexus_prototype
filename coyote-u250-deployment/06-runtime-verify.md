# 阶段 5 —— 加载驱动并端到端验证

**耗时：** 约 15 分钟 · **是否碰硬件：** 是 · **风险：** 低（驱动加载失败用 `rmmod` 即可恢复）

---

## 5.1 前置检查

```bash
lspci -Dn -d 10ee:                    # 必须显示 10ee:903f
grep HugePages_Total /proc/meminfo    # 必须 >= 1024
lsmod | grep coyote                   # 应该为空
```

如果板卡仍显示 `0xd004`，回到
[05-flash-over-pcie.md](05-flash-over-pcie.md#46-如果板卡仍显示-0xd004)。

---

## 5.2 插入驱动

```bash
cd <本文档目录>/scripts

sudo ./50_load_driver.sh --driver ~/fpga/Coyote/driver/build/coyote_driver.ko
```

脚本会检查板卡 device id、确认 hugepages、插入模块，然后打印新增的内核日志和创建的设备节点。

手工等效操作：

```bash
sudo insmod ~/fpga/Coyote/driver/build/coyote_driver.ko
dmesg | tail -40
```

仅当构建启用了网络（`EN_NET=1`）时，才需要以十六进制传入 FPGA 的地址：

```bash
sudo ./50_load_driver.sh \
    --driver ~/fpga/Coyote/driver/build/coyote_driver.ko \
    --ip 0x0A0A0A0A --mac 0x000A35029DE5
```

跑示例 1 不需要这两个参数。

---

## 5.3 成功的标志

Coyote 官方文档给出的判断依据是内核日志的最后一行：

```
probe returning 0
```

检查：

```bash
dmesg | tail -40 | grep "probe returning 0"
```

在这之前，你应该能看到驱动映射 BAR、配置 MSI-X、初始化 XDMA 引擎、注册设备：

```
fpga device id 0, pci bus 1a, pci slot 00
BAR0 at 0x... mapped at 0x..., length=...
...
probe returning 0
```

设备节点：

```bash
ls -l /dev/fpga*
```

应该有 `/dev/fpga_0`（每个 vFPGA 一个，示例 1 是 `N_REGIONS 1`）和 `/dev/fpga_0_reconfig`。

再确认驱动确实认领了设备：

```bash
BDF=$(lspci -Dn -d 10ee: | awk '{print $1}' | head -1)
basename "$(readlink /sys/bus/pci/devices/$BDF/driver)"
```

预期输出 `coyote_driver`。

---

## 5.4 运行示例 1

```bash
cd ~/fpga/Coyote/examples/01_hello_world/sw/build_sw
./test
```

这个示例会分配主机和板卡缓冲、把数据经 vFPGA 搬运一遍、然后校验结果。它把整条链路都跑了一遍：
驱动、DMA、TLB、vFPGA 逻辑和 C++ 运行时。

建议先读它做了什么：

```bash
cat ~/fpga/Coyote/examples/01_hello_world/README.md
```

`test` 使用 Boost program_options 解析参数，但没有接`--help`，所以查看可用参数要看源码：

```bash
grep -n "add_options\|value<" ../src/main.cpp | head -20
```

### 如果失败

| 现象 | 可能原因 |
|---|---|
| 无法打开 `/dev/fpga_0` | 驱动未加载，或权限问题 —— 试试 `sudo` |
| Hugepage allocation failed | 预留更多：`sudo ./10_setup_host.sh --hugepages 4096` |
| 卡住不动 | 查 `dmesg` 是否有 page fault 或 TLB 错误 |
| 结果不对 | 可能是 bitstream 时序违例，回查 `bitgen.log` |

---

## 5.5 让配置持久化

**驱动不会自动重新加载。** 每次重启后需要：

```bash
sudo ./50_load_driver.sh --driver ~/fpga/Coyote/driver/build/coyote_driver.ko
```

而 flash 镜像**是持久的**，所以每次冷启动板卡都会以 Coyote 身份出现。

想开机自动加载，可以建一个 systemd 服务：

```ini
# /etc/systemd/system/coyote-driver.service
[Unit]
Description=Load the Coyote FPGA driver
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/insmod /home/USER/fpga/Coyote/driver/build/coyote_driver.ko
ExecStop=/sbin/rmmod coyote_driver

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now coyote-driver
```

把 `USER` 替换成你的用户名，并使用绝对路径。**内核升级后必须重新编译模块**，否则这个服务会在
开机时失败。

---

## 5.6 以后如何重新烧写

要换一个 Coyote bitstream：

```bash
sudo rmmod coyote_driver          # 务必先卸载
sudo ./40_flash_over_pcie.sh --mcs-stem <新的>/coyote_u250
sudo ipmitool chassis power cycle
sudo ./50_load_driver.sh --driver .../coyote_driver.ko
```

先卸载驱动可以让 DMA 引擎干净停止，避免 PCIe 报错。

好消息是：**一旦 Coyote shell 跑起来，以后改动不必每次都全量重刷 flash。** Coyote 支持运行时
重构整个 shell 或单个 vFPGA，用的是 `bitstreams/` 目录下的 `.bin` 文件。参见 Coyote 的示例 5
和示例 10。

---

## 验收标准

- [ ] `dmesg` 中出现 `probe returning 0`
- [ ] `/dev/fpga_0` 和 `/dev/fpga_0_reconfig` 存在
- [ ] `/sys/bus/pci/devices/<BDF>/driver` 指向 `coyote_driver`
- [ ] `./test` 运行并报告成功

到这里 Coyote 就完整部署好了。接下来可以看 `Coyote/examples/` 里的其他示例，或者用 Python
运行时 [pyCoyote](https://github.com/fpgasystems/pyCoyote)。
