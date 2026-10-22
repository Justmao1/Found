#!/usr/bin/env python3
"""Run the actual Swift client against an isolated, simulated four-locker server.

Recognition fixtures and a deterministic search provider replace cloud calls.
HTTP handlers, SQLite allocation, completion, recovery and the Swift API are real.
No Raspberry Pi, GPIO package, cloud credentials or production data are used.
"""

from datetime import datetime
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import tempfile
import time
import uuid
from unittest.mock import patch
from zoneinfo import ZoneInfo

from verify_api_integration import png_fixture


APP_ROOT = Path(__file__).resolve().parents[1]
BACKEND_ROOT = APP_ROOT / "lost-found-box"
EVIDENCE = APP_ROOT / "verification" / "locker-integration.txt"


def serve_fixture(directory):
    """Internal child process: bind loopback and audit the simulated pulse boundary."""
    if os.environ.get("LOST_FOUND_LOCKER_MODE") != "simulated":
        raise RuntimeError("The integration server requires explicit simulated mode")
    sys.path.insert(0, str(BACKEND_ROOT))
    import lockers
    import server as backend

    door_control = directory / "door-state.json"
    door_control.write_text(json.dumps({"state": "open"}), encoding="utf-8")

    class FixtureDoorMonitor:
        enabled = True

        def start(self):
            pass

        def close(self):
            pass

        def snapshot(self, compartment):
            configured = compartment == "01"
            state = json.loads(door_control.read_text())["state"] if configured else "not_configured"
            return {"enabled": configured, "gpio": 12 if configured else None,
                    "pin": 32 if configured else None, "state": state,
                    "level": (0 if state == "closed" else 1) if configured else None,
                    "updated_at": time.time() if configured else None, "error": None}

    app = backend.build_server("127.0.0.1", 0, directory / "data", auto_recognize=False,
                               door_monitor=FixtureDoorMonitor())
    if not isinstance(app.lockers.driver, lockers.SimulatedDriver) or "lgpio" in sys.modules:
        app.server_close()
        raise RuntimeError("Integration must not initialize physical GPIO")
    identifiers = [str(uuid.uuid5(uuid.NAMESPACE_URL, f"lost-found-locker-fixture:{index}"))
                   for index in range(7)]
    db = app.connect_db()
    try:
        with db:
            for index, identifier in enumerate(identifiers):
                db.execute("INSERT INTO items VALUES (?,?,?,?,?,?,?)",
                           (identifier, str(uuid.uuid4()), f"fixture-{index}",
                            "2026-10-22T00:00:00.000Z", f"蓝色钥匙扣 {index + 1}",
                            "image/png", png_fixture()))
                if index < 6:
                    recognition = backend.vision.validate_recognition({"tags": ["keys", "blue"]}, "fixture-only")
                    db.execute("INSERT INTO recognitions VALUES (?,?)", (identifier, json.dumps(recognition)))
    finally:
        db.close()
    (directory / "items.json").write_text(json.dumps(identifiers), encoding="utf-8")
    audit = directory / "pulses.jsonl"
    audit.write_text("", encoding="utf-8")

    def record_pulse(compartment):
        with audit.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({"compartment": compartment}) + "\n")

    def fixture_search(query, inventory):
        return [{"id": item["id"], "reason": "Fixture tags match the described blue keys."}
                for item in inventory]

    try:
        with patch.object(app.lockers.driver, "pulse", record_pulse), \
                patch.object(backend.search, "find_matches", fixture_search):
            print(f"http://127.0.0.1:{app.server_port}", flush=True)
            app.serve_forever()
    finally:
        app.server_close()


def run():
    lines = ["Lost & Found — Swift / Python four-compartment integration",
             datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(timespec="seconds"),
             "Isolation: temporary SQLite, simulated relays, fixture recognition/search, loopback HTTP."]
    environment = os.environ.copy()
    for name in ("DASHSCOPE_API_KEY", "LOST_FOUND_LOCKER_GPIO_MAP", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                 "http_proxy", "https_proxy", "all_proxy"):
        environment.pop(name, None)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["LOST_FOUND_LOCKER_MODE"] = "simulated"
    environment["LOST_FOUND_VIBRATION_ENABLED"] = "0"
    environment["LOST_FOUND_DOOR_FEEDBACK_ENABLED"] = "0"
    environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    server = None
    temporary_path = None
    exit_code = 1
    try:
        with tempfile.TemporaryDirectory(prefix="lost-found-locker-integration-") as temporary:
            temporary_path = Path(temporary)
            config = temporary_path / "ai-disabled.json"
            config.write_text("{}\n", encoding="utf-8")
            environment["LOST_FOUND_AI_CONFIG"] = str(config)
            executable = temporary_path / "locker-integration"
            sources = sorted((APP_ROOT / "Lost&Found" / "Core").glob("*.swift"))
            result = subprocess.run(
                ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", *map(str, sources),
                 str(APP_ROOT / "Tools" / "LockerIntegration.swift"), "-o", str(executable)],
                env=environment, capture_output=True, text=True, timeout=90, check=False,
            )
            if result.returncode:
                raise RuntimeError("Swift harness compilation failed:\n" + result.stderr.strip())
            lines.append("PASS build: actual Core sources compiled with Swift 6")
            server = subprocess.Popen(
                [sys.executable, "-B", "-u", str(Path(__file__).resolve()), "--serve", temporary],
                env=environment, cwd=APP_ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(server.stdout, selectors.EVENT_READ)
                    if not selector.select(timeout=10):
                        raise RuntimeError("Local fixture server did not become ready within 10 seconds")
                    startup = server.stdout.readline().strip()
                if not re.fullmatch(r"http://127\.0\.0\.1:\d+", startup):
                    raise RuntimeError("Fixture server failed to report its loopback address")
                result = subprocess.run(
                    [str(executable), startup, str(temporary_path / "items.json"),
                     str(temporary_path / "pulses.jsonl"), str(temporary_path / "door-state.json")],
                    env=environment, capture_output=True, text=True, timeout=45, check=False,
                )
                lines.extend(result.stdout.strip().splitlines())
                if result.stderr.strip():
                    lines.extend(result.stderr.strip().splitlines())
                exit_code = result.returncode
            finally:
                server.terminate()
                try:
                    _, errors = server.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    _, errors = server.communicate(timeout=5)
                if exit_code and errors.strip():
                    lines.append("Server diagnostics:\n" + errors.strip())
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        lines.append("FAIL: " + str(error))
    finally:
        if server is not None and server.poll() is None:
            server.kill()
            server.communicate(timeout=5)
        cleaned = temporary_path is None or not temporary_path.exists()
        terminated = server is None or server.poll() is not None
        lines.append("PASS cleanup: fixture server stopped and temporary state removed"
                     if cleaned and terminated else "FAIL cleanup: temporary state or process remains")
        if not (cleaned and terminated):
            exit_code = 1
        EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
        EVIDENCE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("\n".join(lines))
    return exit_code


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--serve":
        serve_fixture(Path(sys.argv[2]))
    elif len(sys.argv) == 1:
        sys.exit(run())
    else:
        sys.exit("Usage: verify_locker_integration.py")
