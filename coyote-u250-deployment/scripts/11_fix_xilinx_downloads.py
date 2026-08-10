#!/usr/bin/env python3
"""
修复 Xilinx 统一安装器下载失败的文件。

背景
----
Xilinx 安装器自带的并发下载器在高延迟跨境链路上会产出 checksum 不匹配的文件。
实测同一个文件用单线程 curl 下载得到的 md5 与期望值完全一致，说明服务器与网络
本身没有问题，问题出在安装器的并发下载逻辑（很可能是 keep-alive 连接复用时
响应错配，因此下载到的仍是合法的 xz 归档，只是内容属于另一个文件）。

本脚本的做法
------------
安装器在失败时会把每个坏文件的 URL 和期望 md5 打进日志。本脚本解析这些信息，
用单线程、不复用连接的方式重新下载，校验 md5，再放回 payload 目录。之后重跑
安装器，它会校验已有文件、跳过正确的，从而继续推进。

用法
    ./fix_xilinx_downloads.py --log ~/vivado_install.log \
        --payload /tools/Xilinx/Downloads/Vivado_2022.1/payload

    # 只查看将要做什么，不实际下载
    ./fix_xilinx_downloads.py --log ... --payload ... --dry-run
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlparse

# 只允许从 AMD/Xilinx 官方下载域名取文件。
# 日志文件可能被改动，这里做白名单校验以避免被诱导访问任意地址（SSRF）。
ALLOWED_HOSTS = {
    "amd-ax-dl.entitlenow.com",
    "xilinx-ax-dl.entitlenow.com",
}

# 形如：
# ERROR - Checksum failed, expected: <md5> but was: <md5> for file<url>
CHECKSUM_RE = re.compile(
    r"Checksum failed, expected:\s*([0-9a-f]{32})\s*but was:\s*[0-9a-f]{32}\s*"
    r"for file\s+(https://\S+)"
)

FILENAME_RE = re.compile(r"filename=([A-Za-z0-9._-]+)")


def md5_of(path, chunk=1 << 20):
    """返回文件的 md5 十六进制串，文件不存在则返回 None。"""
    if not os.path.isfile(path):
        return None
    h = hashlib.md5()
    with open(path, "rb") as fh:
        while True:
            buf = fh.read(chunk)
            if not buf:
                break
            h.update(buf)
    return h.hexdigest()


def parse_log(log_path):
    """从安装器日志中提取 (期望md5, url, 文件名) 三元组，按文件名去重。"""
    try:
        with open(log_path, "r", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        sys.exit(f"错误: 无法读取日志 {log_path}: {exc}")

    found = {}
    for expected_md5, url in CHECKSUM_RE.findall(text):
        url = url.rstrip(".,;)")

        host = urlparse(url).hostname or ""
        if host not in ALLOWED_HOSTS:
            print(f"  跳过非白名单域名: {host}")
            continue

        m = FILENAME_RE.search(url)
        if not m:
            print(f"  跳过无法解析文件名的 URL: {url[:80]}...")
            continue
        name = m.group(1)

        # 文件名必须是安装器的payload 命名，避免路径穿越。
        if not re.fullmatch(r"rdi_\d+_[0-9.]+_\d+_\d+\.xz", name):
            print(f"  跳过异常文件名: {name}")
            continue

        # 同一文件可能失败多次，保留最后一条（URL 最新）。
        found[name] = (expected_md5, url)

    return found


def download(url, dest, timeout=1800):
    """单线程下载 url 到 dest。使用 curl 并禁用连接复用。"""
    cmd = [
        "curl",
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--no-keepalive",      # 关键：不复用连接，避免响应错配
        "--http1.1",           # 避免 HTTP/2 多路复用
        "--retry", "3",
        "--retry-delay", "5",
        "--max-time", str(timeout),
        "--output", dest,
        url,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return False, (proc.stderr or "").strip()
    return True, ""


def main():
    ap = argparse.ArgumentParser(
        description="重新下载 Xilinx 安装器 checksum 校验失败的文件。"
    )
    ap.add_argument("--log", required=True, help="安装器日志路径")
    ap.add_argument("--payload", required=True, help="payload 目录路径")
    ap.add_argument("--dry-run", action="store_true", help="只显示计划，不下载")
    args = ap.parse_args()

    if not shutil.which("curl"):
        sys.exit("错误: 未找到 curl")

    payload = os.path.abspath(args.payload)
    if not os.path.isdir(payload):
        sys.exit(f"错误: payload 目录不存在: {payload}")

    print(f"日志   : {args.log}")
    print(f"payload: {payload}")
    print()

    print("== 解析日志 ==")
    targets = parse_log(args.log)
    if not targets:
        print("日志中没有找到 checksum 失败记录。")
        print("如果安装器仍在报错，请确认日志路径是否正确。")
        return 0
    print(f"共发现 {len(targets)} 个需要修复的文件。")
    print()

    print("== 检查现有文件 ==")
    todo = []
    for name, (expected, url) in sorted(targets.items()):
        path = os.path.join(payload, name)
        actual = md5_of(path)
        if actual == expected:
            print(f"  已正确  {name}")
        else:
            state = "缺失" if actual is None else "损坏"
            print(f"  待下载  {name}  ({state})")
            todo.append((name, expected, url))
    print()

    if not todo:
        print("所有文件均已校验通过，可以直接重跑安装器。")
        return 0

    print(f"== 需要下载 {len(todo)} 个文件 ==")
    if args.dry_run:
        for name, expected, url in todo:
            print(f"  {name}  <- {url[:70]}...")
        print("\n(dry-run，未实际下载)")
        return 0

    ok = 0
    failed = []
    for idx, (name, expected, url) in enumerate(todo, 1):
        dest = os.path.join(payload, name)
        print(f"[{idx}/{len(todo)}] {name}", flush=True)

        # 先下到临时文件，校验通过后再落盘，避免留下半成品。
        tmp_fd, tmp_path = tempfile.mkstemp(dir=payload, prefix=".dl_", suffix=".tmp")
        os.close(tmp_fd)
        try:
            good, err = download(url, tmp_path)
            if not good:
                print(f"         下载失败: {err[:120]}")
                failed.append(name)
                continue

            actual = md5_of(tmp_path)
            if actual != expected:
                print(f"         校验失败: 期望 {expected} 实得 {actual}")
                failed.append(name)
                continue

            os.replace(tmp_path, dest)
            size_mb = os.path.getsize(dest) / (1024 * 1024)
            print(f"         OK  {size_mb:.1f} MB  md5 校验通过")
            ok += 1
        finally:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)

    print()
    print("== 结果 ==")
    print(f"  成功: {ok}")
    print(f"  失败: {len(failed)}")
    if failed:
        print()
        print("以下文件仍未修复:")
        for n in failed:
            print(f"  {n}")
        print()
        print("URL 可能已过期（注意 URL 中的 expires 参数）。")
        print("请重跑一次安装器以获取新的下载链接，然后再次运行本脚本。")
        return 1

    print()
    print("全部修复完成。现在重跑安装器，它会跳过已校验通过的文件：")
    print("  screen -dmS vivado_install /tmp/run_vivado_install.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
