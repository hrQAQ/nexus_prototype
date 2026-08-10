#!/usr/bin/env bash
#
# 13_install_vivado_auto.sh -- 自动循环安装 Vivado，直到成功或无法继续。
#
# 为什么需要这个脚本
# ------------------
# Xilinx 安装器自带的并发下载器在高延迟/跨境链路上会产出checksum 不匹配的文件。
# 每跑一轮安装器，只会暴露出当轮失败的那些文件，因此需要反复
#跑安装器 -> 修复坏文件 -> 再跑安装器
# 才能逐步推进。本脚本把这个循环自动化，无需人工守着。
#
# 每一轮的流程
#   1. 确认认证 token 有效（无效则尝试自动生成，见 --auto-token）
#   2. 运行安装器
#   3. 成功则退出
#   4. 失败则解析日志，用单线程 curl 重新下载校验失败的文件
#   5. 若本轮没有修复任何文件（无进展），停止并报告
#
# 用法
#   ./13_install_vivado_auto.sh [选项]
#
#   --installer DIR    已解压的安装器目录（默认 /tmp/xlnx_installer）
#   --config FILE      安装配置文件（默认 ~/.Xilinx/install_config_coyote_u250.txt）
#   --dest DIR         安装目标目录（默认 /tools/Xilinx，需与配置文件一致）
#   --log FILE         日志路径（默认 ~/vivado_install.log）
#   --max-rounds N     最多循环轮数（默认 20）
#   --auto-token       token 失效时自动重新生成，需要 XILINX_USER/XILINX_PASS
#   --dry-run          只检查前置条件，不实际安装
#
# 建议放进 screen 运行：
#   screen -dmS vivado./13_install_vivado_auto.sh
#   screen -r vivado

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALLER_DIR=/tmp/xlnx_installer
CONFIG="$HOME/.Xilinx/install_config_coyote_u250.txt"
DEST=/tools/Xilinx
LOG="$HOME/vivado_install.log"
MAX_ROUNDS=20
AUTO_TOKEN=0
DRY_RUN=0

TOKEN_FILE="$HOME/.Xilinx/wi_authentication_key"
FIX_SCRIPT="$SCRIPT_DIR/11_fix_xilinx_downloads.py"
TOKEN_SCRIPT="$SCRIPT_DIR/12_xilinx_auth_token.py"

while (( $# )); do
    case "$1" in
        --installer)  INSTALLER_DIR=${2:?}; shift 2 ;;
        --config)     CONFIG=${2:?};        shift 2 ;;
        --dest)       DEST=${2:?};          shift 2 ;;
        --log)        LOG=${2:?};           shift 2 ;;
        --max-rounds) MAX_ROUNDS=${2:?};    shift 2 ;;
        --auto-token) AUTO_TOKEN=1;         shift ;;
        --dry-run)    DRY_RUN=1;            shift ;;
        -h|--help)    sed -n '2,32p' "$0";  exit 0 ;;
        *) echo "错误: 未知参数 '$1'" >&2; exit 1 ;;
    esac
done

if ! [[ "$MAX_ROUNDS" =~ ^[0-9]+$ ]] || (( MAX_ROUNDS < 1 )); then
    echo "错误: --max-rounds 必须是正整数" >&2
    exit 1
fi

say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n========== %s ==========\n' "$*"; }
stamp(){ date '+%F %T'; }

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
hdr "前置检查"

XSETUP="$INSTALLER_DIR/xsetup"
if [[ ! -x "$XSETUP" ]]; then
    say "错误: 找不到可执行的 xsetup: $XSETUP"
    say "      请先解压安装器："
    say "      ./Xilinx_Unified_*.bin --noexec --target $INSTALLER_DIR"
    exit 1
fi
say "安装器  : $INSTALLER_DIR"

if [[ ! -f "$CONFIG" ]]; then
    say "错误: 找不到配置文件: $CONFIG"
    say "      生成模板：printf '2\\n1\\n' | $XSETUP -b ConfigGen"
    exit 1
fi
say "配置: $CONFIG"

# 从配置中读出真实安装路径，避免与 --dest 不一致导致找错 payload。
CFG_DEST=$(grep -E '^\s*Destination=' "$CONFIG" | tail -1 | cut -d= -f2- | xargs)
if [[ -n "$CFG_DEST" && "$CFG_DEST" != "$DEST" ]]; then
    say "提示: 配置文件里的 Destination=$CFG_DEST，以它为准"
    DEST=$CFG_DEST
fi
say "目标目录: $DEST"

if [[ ! -f "$FIX_SCRIPT" ]]; then
    say "错误: 找不到修复脚本: $FIX_SCRIPT"
    exit 1
fi

for tool in curl python3 grep; do
    command -v "$tool" >/dev/null 2>&1 || { say "错误: 缺少 $tool"; exit 1; }
done

if [[ ! -d "$DEST" ]]; then
    say "提示: $DEST 不存在，尝试创建"
    mkdir -p "$DEST" 2>/dev/null || {
        say "错误: 无法创建 $DEST。请先执行："
        say "      sudo mkdir -p $DEST && sudo chown -R \$USER:\$USER $DEST"
        exit 1
    }
fi
if [[ ! -w "$DEST" ]]; then
    say "错误: $DEST 不可写。请执行："
    say "      sudo chown -R \$USER:\$USER $DEST"
    exit 1
fi

# payload 目录由安装器在首轮创建，此处只推导路径。
PAYLOAD="$DEST/Downloads/Vivado_2022.1/payload"
say "payload : $PAYLOAD"

AVAIL_GB=$(df -BG --output=avail "$DEST" | tail -1 | tr -dc '0-9')
say "可用空间: ${AVAIL_GB} GB"
if (( AVAIL_GB < 150 )); then
    say "警告: 可用空间不足 150 GB，安装可能失败"
fi

if (( DRY_RUN )); then
    hdr "dry-run 结束"
    say "前置检查通过，未执行安装。"
    exit 0
fi

# ---------------------------------------------------------------------------
# token 检查
# ---------------------------------------------------------------------------
ensure_token() {
    # token 有效期约 7 天，这里以 6 天为界。
    if [[ -s "$TOKEN_FILE" ]]; then
        local age_s now mtime
        now=$(date +%s)
        mtime=$(stat -c %Y "$TOKEN_FILE")
        age_s=$(( now - mtime ))
        if (( age_s < 6 * 24 * 3600 )); then
            printf '  token 有效（生成于 %d 小时前）\n' $(( age_s / 3600 ))
            return 0
        fi
        say "  token 已超过 6 天，需要刷新"
    else
        say "  token 不存在"
    fi

    if (( AUTO_TOKEN )); then
        if [[ ! -f "$TOKEN_SCRIPT" ]]; then
            say "  错误: 找不到 $TOKEN_SCRIPT"
            return 1
        fi
        if [[ -z "${XILINX_USER:-}" || -z "${XILINX_PASS:-}" ]]; then
            say "  错误: --auto-token 需要环境变量 XILINX_USER 和 XILINX_PASS"
            say "        export XILINX_USER='you@example.com'"
            say "        read -rs XILINX_PASS && export XILINX_PASS"
            return 1
        fi
        say "  正在自动生成 token ..."
        python3 "$TOKEN_SCRIPT" --installer "$INSTALLER_DIR" --force || return 1
        return 0
    fi

    say ""
    say "  请手动生成 token，然后重新运行本脚本："
    say "cd $INSTALLER_DIR && ./xsetup -b AuthTokenGen"
    say ""
    say "  或者使用 --auto-token 配合环境变量实现无人值守。"
    return 1
}

# ---------------------------------------------------------------------------
# 主循环
# ---------------------------------------------------------------------------
hdr "开始安装  $(stamp)"
say "最多$MAX_ROUNDS 轮"

ROUND=0
while (( ROUND < MAX_ROUNDS )); do
    ROUND=$(( ROUND + 1 ))

    hdr "第 $ROUND/$MAX_ROUNDS 轮  $(stamp)"

    say "-- 检查 token --"
    if ! ensure_token; then
        say""
        say "token 不可用，终止。"
        exit 1
    fi

    # 每轮单独留一份日志，便于事后追溯；同时汇总到主日志。
    ROUND_LOG="${LOG%.log}.round${ROUND}.log"

    say "-- 运行安装器 --"
    say "   日志: $ROUND_LOG"

    set +e
    ( cd "$INSTALLER_DIR" && \
      LANG=C.UTF-8 LC_ALL=C.UTF-8 ./xsetup \
          --agree XilinxEULA,3rdPartyEULA \
          --batch Install \
          --config "$CONFIG" ) > "$ROUND_LOG" 2>&1
    RC=$?
    set -e

    cat "$ROUND_LOG" >> "$LOG"

    say "   退出码: $RC"

    if (( RC == 0 )); then
        hdr "安装成功  $(stamp)"
        say "共 $ROUND 轮。"
        say ""
        say "下一步："
        say "  source $DEST/Vivado/2022.1/settings64.sh"
        say "  vivado -version"
        exit 0
    fi

    # 判断失败原因，避免在不可恢复的错误上空转。
    if grep -q "you must generate an authentication token" "$ROUND_LOG"; then
        say "   原因: token 失效"
        # 强制下一轮重新生成。
        rm -f "$TOKEN_FILE"
        continue
    fi

    CKSUM_COUNT=$(grep -c "Checksum failed" "$ROUND_LOG" 2>/dev/null || true)
    CKSUM_COUNT=${CKSUM_COUNT:-0}

    if (( CKSUM_COUNT == 0 )); then
        hdr "安装失败，且不是下载校验问题"
        say "本轮没有出现 Checksum failed，自动修复无从下手。"
        say ""
        say "请检查日志末尾："
        say "  tail -40 $ROUND_LOG"
        say ""
        grep -E "^ERROR" "$ROUND_LOG" | tail -10 | sed 's/^/  /'
        exit 1
    fi

    say "   原因: $CKSUM_COUNT 个文件校验失败"

    if [[ ! -d "$PAYLOAD" ]]; then
        say "   错误: payload 目录不存在: $PAYLOAD"
        say "        请确认 --dest 与配置文件中的 Destination 一致。"
        exit 1
    fi

    say ""
    say "-- 修复损坏文件 --"

    FIX_LOG="${LOG%.log}.fix${ROUND}.log"
    set +e
    python3 "$FIX_SCRIPT" --log "$ROUND_LOG" --payload "$PAYLOAD" 2>&1 | tee "$FIX_LOG"
    set -e

    FIXED=$(grep -c "md5 校验通过" "$FIX_LOG" 2>/dev/null || true)
    FIXED=${FIXED:-0}
    say ""
    say "   本轮修复: $FIXED 个文件"

    if (( FIXED == 0 )); then
        hdr "无进展，终止"
        say "本轮一个文件都没能修复。常见原因："
        say ""
        say "  1. 日志中的下载链接已过期（URL 里的 expires 参数）。"
        say "     再跑一次安装器可以拿到新链接。"
        say "  2. 网络无法访问 AMD 下载服务器。"
        say ""
        say "如果这个问题反复出现，建议改用约 74 GB 的离线完整安装包："
        say "  它是单个文件，可用 wget -c 断点续传，不经过安装器的下载器。"
        exit 1
    fi

    say "   继续下一轮 ..."
done

hdr "达到最大轮数 $MAX_ROUNDS"
say "仍未安装成功。可以提高 --max-rounds 继续，或改用离线完整安装包。"
exit 1
