# nexus_prototype

Nexus 项目的原型仓库，收集与部署、验证相关的**可执行文档与脚本**。当前唯一的子项目是
Coyote on Alveo U250 的部署指南。

## 子项目

### [`coyote-u250-deployment/`](coyote-u250-deployment/) —— 在 Alveo U250 上部署 Coyote

在 AMD Alveo U250 上部署 [Coyote](https://github.com/fpgasystems/Coyote) FPGA shell，
**全程不需要 JTAG 线**：通过 PCIe 写入板载 flash，整个流程可以远程完成。

包含 8 篇按阶段编号的文档，覆盖从环境审计到运行时验证的完整链路；配套 10 个幂等
脚本，用于自动化安装 Vivado、编译工具链、烧写 flash 与加载驱动。

详见 [`coyote-u250-deployment/README.md`](coyote-u250-deployment/README.md)。

## 目录布局

```
nexus_prototype/
├── coyote-u250-deployment/   # Coyote on Alveo U250 部署指南（文档 + 脚本）
├── upstream/                 # 所有上游代码，作为 git submodule 锁定到具体 commit
│   └── Coyote/               #   fpgasystems/Coyote  (master, gh-proxy URL)
├── scripts/
│   └── bootstrap.sh          # 新机器一键初始化（配 gh-proxy + init submodule）
├── .gitmodules
├── .gitignore
└── README.md      # 本文件
```

## 在新机器上快速部署

```bash
git clone git@github.com:hrQAQ/nexus_prototype.git
cd nexus_prototype
./scripts/bootstrap.sh           # 拉上游代码，走 gh-proxy
# 之后按 coyote-u250-deployment/README.md 的 Quick Start 继续
```

细节见 [`coyote-u250-deployment/README.md`](coyote-u250-deployment/README.md#quick-start新机器一键落地)。

## 约定

- 文档正文用中文；脚本内的注释与输出保持英文，方便在不同 locale 的终端下显示，也
  便于粘贴到 issue 里提问。
- 每份指南标注「已在真实硬件上验证」还是「未验证」，两者不要混淆。
- 脚本都写成幂等，多次运行不会破坏之前的状态。
