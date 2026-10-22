#!/usr/bin/env python3
"""Set a station-only administrator password without shell arguments or logs."""

import argparse
import getpass
import os
from pathlib import Path
import secrets
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generate", action="store_true", help="write a random password; read the protected file locally")
    args = parser.parse_args()
    target = Path(os.environ.get("LOST_FOUND_ADMIN_PASSWORD_FILE", ROOT / "config/admin-password.txt"))
    if args.generate:
        if target.exists():
            sys.exit("密码文件已存在，未覆盖。修改密码请在终端交互运行本脚本。")
        password = secrets.token_urlsafe(24)
    else:
        if not sys.stdin.isatty():
            sys.exit("请在交互式终端运行；通过 SSH 时使用 ssh -t。")
        password = getpass.getpass("新管理员密码（12–256 个字符）: ")
        if password != getpass.getpass("再次输入: "):
            sys.exit("两次输入不一致，原配置未改变。")
    if password != password.strip() or not 12 <= len(password) <= 256:
        sys.exit("密码必须为 12–256 个字符，首尾不能有空白。")
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".admin-", dir=target.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(password + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        if Path(temporary).exists():
            Path(temporary).unlink()
    print(f"管理员密码已保存至 {target}（权限 600）。重启服务后生效，旧会话将失效。")


if __name__ == "__main__":
    main()
