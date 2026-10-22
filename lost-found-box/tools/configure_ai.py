#!/usr/bin/env python3
"""Configure Bailian locally without putting a key in shell history or output."""

import getpass
import json
import os
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import vision


def main():
    if not sys.stdin.isatty():
        sys.exit("请在交互式终端运行；通过 SSH 时使用 ssh -t。")
    target = Path(os.environ.get("LOST_FOUND_AI_CONFIG", ROOT / "config" / "ai.json"))
    print("百炼北京地域配置。API Key 输入时不显示，也不会打印。")
    key = getpass.getpass("API Key: ").strip()
    if not key:
        sys.exit("未输入 Key，原配置保持不变。")
    model = input(f"视觉模型 [{vision.DEFAULT_MODEL}]: ").strip() or vision.DEFAULT_MODEL
    workspace = input("业务空间 ID（留空使用仍受支持的北京公共域名）: ").strip()
    base_url = (f"https://{workspace}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
                if workspace else vision.DEFAULT_BASE_URL)
    config = {"api_key": key, "model": model, "base_url": base_url}
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = None
    old_path = os.environ.get("LOST_FOUND_AI_CONFIG")
    old_key = os.environ.pop("DASHSCOPE_API_KEY", None)
    try:
        fd, temporary = tempfile.mkstemp(prefix=".ai-", suffix=".json", dir=target.parent)
        with os.fdopen(fd, "w") as stream:
            json.dump(config, stream)
        os.environ["LOST_FOUND_AI_CONFIG"] = temporary
        vision.load_config()
        os.replace(temporary, target)
        print("配置已保存（仅当前用户可读写）。刷新登记页后即可识别物品。")
    except vision.VisionError as error:
        sys.exit(error.message)
    finally:
        if temporary and Path(temporary).exists():
            Path(temporary).unlink()
        if old_path is None:
            os.environ.pop("LOST_FOUND_AI_CONFIG", None)
        else:
            os.environ["LOST_FOUND_AI_CONFIG"] = old_path
        if old_key is not None:
            os.environ["DASHSCOPE_API_KEY"] = old_key


if __name__ == "__main__":
    main()
