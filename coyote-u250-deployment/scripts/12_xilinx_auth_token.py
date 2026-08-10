#!/usr/bin/env python3
"""
自动生成 Xilinx 安装器所需的认证 token。

背景
----
Xilinx 统一安装器在批量模式下载之前，要求先用
    xsetup -b AuthTokenGen
生成认证 token。该命令是交互式的，会依次询问 AMD 账号邮箱和密码，因此无法直接
写进无人值守脚本。本脚本用伪终端（pty）驱动它，实现自动化。

Token 会保存到 ~/.Xilinx/wi_authentication_key，权限 0400，有效期约 7 天。
过期后重新运行本脚本即可。

安全设计
--------
* 密码只从环境变量读取，绝不接受命令行参数（命令行对 `ps` 全局可见）。
* 密码不落盘、不写日志，脚本输出中会被替换为掩码。
* 若环境变量未设置且终端可交互，则回退为安全的隐式输入（getpass）。

用法
    export XILINX_USER='you@example.com'
    read -rs XILINX_PASS && export XILINX_PASS      # 输入时不回显
    ./12_xilinx_auth_token.py --installer /tmp/xlnx_installer

    # 用完立刻清除
    unset XILINX_PASS

若已存在有效 token，脚本会直接退出；加 --force 可强制重新生成。
"""

import argparse
import getpass
import os
import pty
import re
import select
import subprocess
import sys
import time

TOKEN_PATH = os.path.expanduser("~/.Xilinx/wi_authentication_key")

# token 有效期约 7 天，留一天余量。
TOKEN_MAX_AGE_SECONDS = 6 * 24 * 3600


def token_is_fresh(path=TOKEN_PATH, max_age=TOKEN_MAX_AGE_SECONDS):
    """token 文件存在、非空且足够新则返回 True。"""
    try:
        st = os.stat(path)
    except OSError:
        return False
    if st.st_size == 0:
        return False
    return (time.time() - st.st_mtime) < max_age


def run_auth_token_gen(installer_dir, email, password, timeout=180):
    """
    在伪终端中运行 `xsetup -b AuthTokenGen`，自动填入邮箱与密码。

    返回 (成功与否, 脱敏后的输出文本)。
    """
    xsetup = os.path.join(installer_dir, "xsetup")
    if not os.path.isfile(xsetup):
        return False, f"未找到 xsetup: {xsetup}"
    if not os.access(xsetup, os.X_OK):
        return False, f"xsetup 不可执行: {xsetup}"

    env = dict(os.environ)
    env["LANG"] = "C.UTF-8"
    env["LC_ALL"] = "C.UTF-8"
    # 防止把密码经由环境泄漏给子进程。
    env.pop("XILINX_PASS", None)

    master, slave = pty.openpty()
    try:
        proc = subprocess.Popen(
            [xsetup, "-b", "AuthTokenGen"],
            cwd=installer_dir,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
            close_fds=True,
        )
    except OSError as exc:
        os.close(master)
        os.close(slave)
        return False, f"启动 xsetup 失败: {exc}"

    os.close(slave)

    transcript = []
    sent_email = False
    sent_password = False
    deadline = time.time() + timeout

    try:
        while True:
            if time.time() > deadline:
                proc.kill()
                return False, "".join(transcript) + "\n[超时]"

            ready, _, _ = select.select([master], [], [], 1.0)
            if ready:
                try:
                    chunk = os.read(master, 4096).decode("utf-8", errors="replace")
                except OSError:
                    break
                if not chunk:
                    break
                transcript.append(chunk)
                tail = "".join(transcript)[-400:]

                # 依次应答两个提示。顺序固定：先邮箱，后密码。
                if not sent_email and re.search(r"E-?mail\s*Address\s*:", tail, re.I):
                    os.write(master, (email + "\n").encode())
                    sent_email = True
                elif sent_email and not sent_password and re.search(r"Password\s*:", tail, re.I):
                    os.write(master, (password + "\n").encode())
                    sent_password = True

            if proc.poll() is not None:
                # 收尾，读干缓冲区。
                while True:
                    ready, _, _ = select.select([master], [], [], 0.3)
                    if not ready:
                        break
                    try:
                        chunk = os.read(master, 4096).decode("utf-8", errors="replace")
                    except OSError:
                        break
                    if not chunk:
                        break
                    transcript.append(chunk)
                break
    finally:
        os.close(master)
        if proc.poll() is None:
            proc.kill()
        proc.wait()

    output = "".join(transcript)

    # 脱敏：即使密码被终端回显，也不会出现在返回值里。
    if password:
        output = output.replace(password, "********")

    success = (
        proc.returncode == 0
        and "Saved authentication token" in output
    )
    return success, output


def main():
    ap = argparse.ArgumentParser(
        description="自动生成 Xilinx 安装器认证 token（密码仅从环境变量读取）。"
    )
    ap.add_argument(
        "--installer",
        default="/tmp/xlnx_installer",
        help="已解压的安装器目录，需包含 xsetup（默认 /tmp/xlnx_installer）",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="即使已有有效 token 也重新生成",
    )
    args = ap.parse_args()

    if token_is_fresh() and not args.force:
        age_h = (time.time() - os.stat(TOKEN_PATH).st_mtime) / 3600
        print(f"已存在有效 token: {TOKEN_PATH}")
        print(f"生成于 {age_h:.1f} 小时前，无需重新生成。")
        print("如需强制刷新，加 --force。")
        return 0

    email = os.environ.get("XILINX_USER", "").strip()
    password = os.environ.get("XILINX_PASS", "")

    if not email:
        if sys.stdin.isatty():
            email = input("AMD 账号邮箱: ").strip()
        else:
            sys.exit("错误: 未设置环境变量 XILINX_USER，且当前非交互终端。")

    if not password:
        if sys.stdin.isatty():
            # 不回显输入。
            password = getpass.getpass("AMD 账号密码（不回显）: ")
        else:
            sys.exit(
                "错误: 未设置环境变量 XILINX_PASS，且当前非交互终端。\n"
                "请先执行:\n"
                "  read -rs XILINX_PASS && export XILINX_PASS"
            )

    if not password:
        sys.exit("错误: 密码为空。")

    print(f"账号: {email}")
    print(f"安装器: {args.installer}")
    print("正在生成 token...")
    print()

    ok, output = run_auth_token_gen(args.installer, email, password)

    # 立即从内存中丢弃密码引用。
    password = None

    # 只打印关键行，避免刷屏。
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        if re.search(r"INFO|ERROR|WARN|token", line, re.I):
            print("  " + line)

    print()
    if ok:
        print(f"成功。token 已保存到 {TOKEN_PATH}")
        try:
            # 确保权限收紧，只有本人可读。
            os.chmod(TOKEN_PATH, 0o400)
            mode = oct(os.stat(TOKEN_PATH).st_mode & 0o777)
            print(f"权限: {mode}")
        except OSError:
            pass
        print()
        print("接下来可以启动安装:")
        print("  screen -dmS vivado_install /tmp/run_vivado_install.sh")
        return 0

    print("失败。请检查账号密码是否正确，以及网络能否访问 AMD 服务器。")
    print("也可以手动执行做对比:")
    print(f"  cd {args.installer} && ./xsetup -b AuthTokenGen")
    return 1


if __name__ == "__main__":
    sys.exit(main())
