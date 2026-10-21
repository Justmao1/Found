#!/usr/bin/env python3
"""Exercise the actual Swift APIClient against an isolated local Python backend."""

from datetime import datetime
import os
from pathlib import Path
import re
import selectors
import struct
import subprocess
import sys
import tempfile
import zlib
from zoneinfo import ZoneInfo


APP_ROOT = Path(__file__).resolve().parents[1]
BACKEND = APP_ROOT.parent / "lost-found-box" / "server.py"
EVIDENCE = APP_ROOT / "verification" / "api-integration.txt"


def png_fixture():
    def chunk(kind, content):
        return (struct.pack(">I", len(content)) + kind + content
                + struct.pack(">I", zlib.crc32(kind + content) & 0xFFFFFFFF))

    # A complete, valid 2x2 RGB PNG, generated without image dependencies.
    pixels = b"\x00\xff\x00\x00\x00\xff\x00\x00\x00\x00\xff\xff\xff\xff"
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels))
            + chunk(b"IEND", b""))


def run():
    lines = ["Lost & Found — Swift APIClient / Python server integration",
             datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(timespec="seconds"),
             "Isolation: temporary database, empty AI config, no API key, 127.0.0.1 only."]
    environment = os.environ.copy()
    environment.pop("DASHSCOPE_API_KEY", None)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
        environment.pop(name, None)
    exit_code = 1
    temporary_path = None
    server = None
    try:
        with tempfile.TemporaryDirectory(prefix="lost-found-swift-integration-") as directory:
            temporary_path = Path(directory)
            config = temporary_path / "ai-disabled.json"
            config.write_text("{}\n", encoding="utf-8")
            environment["LOST_FOUND_AI_CONFIG"] = str(config)
            fixture = temporary_path / "fixture.png"
            fixture.write_bytes(png_fixture())
            executable = temporary_path / "api-integration"
            sources = sorted((APP_ROOT / "Lost&Found" / "Core").glob("*.swift"))
            if not sources:
                raise RuntimeError("Core Swift sources were not found")
            compile_result = subprocess.run(
                ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                 *map(str, sources), str(APP_ROOT / "Tools" / "APIIntegration.swift"),
                 "-o", str(executable)],
                env=environment, capture_output=True, text=True, timeout=90, check=False,
            )
            if compile_result.returncode:
                raise RuntimeError("Swift harness compilation failed:\n" + compile_result.stderr.strip())
            lines.append("PASS build: actual Core sources compiled with Swift 6")
            server = subprocess.Popen(
                [sys.executable, "-B", "-u", str(BACKEND), "--host", "127.0.0.1",
                 "--port", "0", "--data-dir", str(temporary_path / "data")],
                env=environment, cwd=BACKEND.parent, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True,
            )
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(server.stdout, selectors.EVENT_READ)
                    if not selector.select(timeout=10):
                        raise RuntimeError("Local test server did not become ready within 10 seconds")
                    startup = server.stdout.readline()
                match = re.search(r"http://127\.0\.0\.1:(\d+)", startup)
                if not match:
                    raise RuntimeError("Local server failed to report a loopback address")
                result = subprocess.run(
                    [str(executable), "http://127.0.0.1:" + match.group(1), str(fixture)],
                    env=environment, capture_output=True, text=True, timeout=45, check=False,
                )
                lines.extend(result.stdout.strip().splitlines())
                if result.stderr.strip():
                    lines.extend(result.stderr.strip().splitlines())
                exit_code = result.returncode
            finally:
                server.terminate()
                try:
                    server.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.communicate(timeout=5)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        lines.append("FAIL: " + str(error))
    finally:
        if server is not None and server.poll() is None:
            server.kill()
            server.communicate(timeout=5)
        cleaned = temporary_path is None or not temporary_path.exists()
        terminated = server is None or server.poll() is not None
        lines.append("PASS cleanup: test server stopped and temporary state removed"
                     if cleaned and terminated else "FAIL cleanup: temporary state or process remains")
        if not (cleaned and terminated):
            exit_code = 1
        EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
        EVIDENCE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("\n".join(lines))
    return exit_code


if __name__ == "__main__":
    sys.exit(run())
