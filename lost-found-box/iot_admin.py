"""Staff sessions and read-only station telemetry, using the standard library."""

from collections import deque
from datetime import datetime, timezone
import hashlib
import hmac
from http.cookies import SimpleCookie, CookieError
import ipaddress
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import socket
import subprocess
import threading
import time

import lockers
import vision

SESSION_SECONDS = 8 * 60 * 60
PHYSICAL_PINS = {"01": 11, "02": 37, "03": 33, "04": 29}
ITEM_FROM = """FROM items
    LEFT JOIN recognitions ON recognitions.item_id=items.id
    LEFT JOIN recognition_jobs ON recognition_jobs.item_id=items.id
    LEFT JOIN item_storage ON item_storage.item_id=items.id"""
ITEM_SELECT = """SELECT items.id,items.created_at,items.note,recognitions.result AS recognition,
    recognition_jobs.state AS recognition_state,item_storage.status AS storage_status,
    item_storage.compartment_id """


def utc_now():
    return datetime.now(timezone.utc).isoformat()


class Sessions:
    def __init__(self):
        path = Path(os.environ.get("LOST_FOUND_ADMIN_PASSWORD_FILE",
                                   Path(__file__).resolve().parent / "config/admin-password.txt"))
        try:
            password = path.read_text(encoding="utf-8").strip()
        except (OSError, UnicodeError):
            password = ""
        self.password_hash = hashlib.sha256(password.encode()).digest() if 12 <= len(password) <= 256 else None
        self.tokens = {}
        self.failures = {}
        self.lock = threading.Lock()

    @property
    def configured(self):
        return self.password_hash is not None

    def token(self, cookie):
        try:
            parsed = SimpleCookie()
            parsed.load(cookie or "")
            return parsed["found_admin"].value if "found_admin" in parsed else ""
        except CookieError:
            return ""

    def authenticated(self, cookie):
        token = self.token(cookie)
        with self.lock:
            expires = self.tokens.get(token, 0)
            if expires <= time.monotonic():
                self.tokens.pop(token, None)
                return False
            return True

    def require(self, cookie):
        if not self.authenticated(cookie):
            raise vision.VisionError(401, "Sign in to the administration console first.")

    def login(self, password, address):
        if not self.configured:
            raise vision.VisionError(503, "Administrator access is not configured. Run tools/configure_admin.py on the Raspberry Pi.")
        if not isinstance(password, str) or not 1 <= len(password) <= 256:
            raise vision.VisionError(400, "Enter a valid administrator password.")
        try:
            digest = hashlib.sha256(password.encode("utf-8")).digest()
        except UnicodeError:
            raise vision.VisionError(400, "The password contains invalid characters.") from None
        now = time.monotonic()
        with self.lock:
            self.tokens = {token: expires for token, expires in self.tokens.items() if expires > now}
            self.failures = {ip: value for ip, value in self.failures.items() if value[1] > now}
            count, until = self.failures.get(address, (0, now + 300))
            if count >= 10:
                raise vision.VisionError(429, "Too many sign-in attempts. Try again in five minutes.")
            if not hmac.compare_digest(digest, self.password_hash):
                if len(self.failures) >= 256 and address not in self.failures:
                    self.failures.pop(next(iter(self.failures)))
                self.failures[address] = (count + 1, until)
                raise vision.VisionError(401, "Incorrect administrator password.")
            self.failures.pop(address, None)
            if len(self.tokens) >= 64:
                self.tokens.pop(next(iter(self.tokens)))
            token = secrets.token_urlsafe(32)
            self.tokens[token] = now + SESSION_SECONDS
            return token

    def logout(self, cookie):
        with self.lock:
            self.tokens.pop(self.token(cookie), None)

    @staticmethod
    def cookie(token, secure=False):
        return (f"found_admin={token}; Path=/api/admin; HttpOnly; SameSite=Strict; "
                f"Max-Age={SESSION_SECONDS if token else 0}" + ("; Secure" if secure else ""))


def read_text(path):
    try:
        return Path(path).read_text().strip().strip("\0")
    except (OSError, UnicodeError):
        return ""


def linux_counters():
    cpu = memory = temperature = uptime = network = None
    try:
        fields = read_text("/proc/stat").splitlines()[0].split()
        values = [int(value) for value in fields[1:9]]  # guest time is already counted
        cpu = (sum(values), values[3] + values[4])
    except (IndexError, ValueError):
        pass
    try:
        fields = dict(line.split(":", 1) for line in read_text("/proc/meminfo").splitlines())
        total = int(fields["MemTotal"].split()[0]) * 1024
        available = int(fields["MemAvailable"].split()[0]) * 1024
        memory = (total, max(0, total - available))
    except (KeyError, ValueError, IndexError):
        pass
    try:
        value = float(read_text("/sys/class/thermal/thermal_zone0/temp")) / 1000
        temperature = value if -20 <= value <= 150 else None
    except ValueError:
        pass
    try:
        uptime = float(read_text("/proc/uptime").split()[0])
    except (ValueError, IndexError):
        pass
    try:
        interfaces = [line.split(":", 1) for line in read_text("/proc/net/dev").splitlines()[2:]]
        counters = [(int(data.split()[0]), int(data.split()[8])) for name, data in interfaces if name.strip() != "lo"]
        if counters:
            network = tuple(sum(pair[i] for pair in counters) for i in (0, 1))
    except (ValueError, IndexError):
        pass
    return cpu, memory, temperature, uptime, network


class Telemetry:
    def __init__(self, directory):
        self.directory = directory
        self.started = time.monotonic()
        self.previous = None
        self.cached = None
        self.history = deque(maxlen=120)
        self.lock = threading.Lock()
        self.hostname = socket.gethostname()
        self.model = read_text("/proc/device-tree/model") or platform.machine()
        self.addresses = []
        self.addresses_at = 0

    def refresh_addresses(self, now):
        if now - self.addresses_at < 30:
            return
        self.addresses_at = now
        if platform.system() == "Linux":
            try:
                output = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=1, check=True).stdout
                self.addresses = [str(ipaddress.ip_address(value)) for value in output.split()][:16]
            except (OSError, ValueError, subprocess.SubprocessError):
                self.addresses = []

    def sample(self):
        with self.lock:
            now = time.monotonic()
            if self.cached and now - self.previous[0] < 3:
                return self.cached
            cpu, memory, temperature, uptime, network = linux_counters()
            cpu_percent = rx_rate = tx_rate = None
            if self.previous:
                before, old_cpu, old_network = self.previous
                elapsed = now - before
                if cpu and old_cpu and cpu[0] > old_cpu[0] and cpu[1] >= old_cpu[1]:
                    cpu_percent = round(max(0, min(100, 100 * (1 - (cpu[1] - old_cpu[1]) / (cpu[0] - old_cpu[0])))), 1)
                if network and old_network and elapsed > 0 and all(network[i] >= old_network[i] for i in (0, 1)):
                    rx_rate, tx_rate = ((network[i] - old_network[i]) / elapsed for i in (0, 1))
            self.previous = (now, cpu, network)
            self.refresh_addresses(now)
            mem = {"total_bytes": None, "used_bytes": None, "percent": None}
            if memory and memory[0] > 0:
                mem = {"total_bytes": memory[0], "used_bytes": memory[1], "percent": round(100 * memory[1] / memory[0], 1)}
            disk_info = {"total_bytes": None, "used_bytes": None, "percent": None}
            try:
                disk = shutil.disk_usage(self.directory)
                if disk.total > 0:
                    disk_info = {"total_bytes": disk.total, "used_bytes": disk.used,
                                 "percent": round(disk.used / disk.total * 100, 1)}
            except OSError:
                pass
            try:
                load = list(os.getloadavg())
            except (OSError, AttributeError):
                load = []
            self.history.append({"at": utc_now(), "cpu_percent": cpu_percent, "memory_percent": mem["percent"],
                                 "cpu_temperature_celsius": temperature,
                                 "rx_bytes_per_second": rx_rate, "tx_bytes_per_second": tx_rate})
            self.cached = ({"name": "Found Station", "hostname": self.hostname, "model": self.model,
                            "platform": platform.system() + " " + platform.release(), "ip_addresses": self.addresses,
                            "service_uptime_seconds": int(now - self.started), "system_uptime_seconds": uptime},
                           {"cpu_percent": cpu_percent, "load_average": load, "cpu_temperature_celsius": temperature,
                            "memory": mem, "disk": disk_info,
                            "network": {"rx_bytes": network[0] if network else None, "tx_bytes": network[1] if network else None,
                                        "rx_bytes_per_second": rx_rate, "tx_bytes_per_second": tx_rate},
                            "history": list(self.history)})
            return self.cached


def gpio_levels(enabled):
    """pinctrl get never claims or writes lines. A sampled level is not a door sensor."""
    if not enabled:
        return {}
    try:
        result = subprocess.run(["pinctrl", "get", "5,13,17,26"], capture_output=True, text=True, timeout=1, check=True)
        return {int(pin): int(level == "hi") for pin, level in
                re.findall(r"^\s*(\d+):[^\n]*\|\s*(hi|lo)\b", result.stdout, re.MULTILINE)}
    except (OSError, subprocess.SubprocessError):
        return {}


class Administration:
    def __init__(self, server, serialize_item):
        self.server = server
        self.serialize_item = serialize_item
        self.sessions = Sessions()
        self.telemetry = Telemetry(server.db_path.parent)

    def items(self, query):
        if set(query) - {"q", "status", "offset", "limit"} or any(len(values) != 1 for values in query.values()):
            raise vision.VisionError(400, "Invalid query parameters.")
        term, status = query.get("q", [""])[0].strip(), query.get("status", [""])[0]
        if len(term) > 200 or status not in ("", "recorded", "deposit_pending", "stored", "retrieval_pending", "collected", "recovery"):
            raise vision.VisionError(400, "Invalid search or status filter.")
        try:
            term.encode("utf-8")
            offset, limit = int(query.get("offset", ["0"])[0]), int(query.get("limit", ["25"])[0])
            if not 0 <= offset <= 10_000_000 or not 1 <= limit <= 100:
                raise ValueError()
        except (ValueError, UnicodeError):
            raise vision.VisionError(400, "Invalid pagination parameters.") from None
        conditions, args = [], []
        if status:
            conditions.append("COALESCE(item_storage.status,'recorded')=?")
            args.append(status)
        if term:
            like = "%" + term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
            conditions.append("(items.id LIKE ? ESCAPE '\\' OR items.note LIKE ? ESCAPE '\\' OR EXISTS ("
                              "SELECT 1 FROM json_each(CASE WHEN json_valid(recognitions.result) "
                              "THEN recognitions.result ELSE '{}' END,'$.tags') AS tag "
                              "WHERE tag.type='text' AND tag.value LIKE ? ESCAPE '\\'))")
            args.extend([like] * 3)
        where = " WHERE " + " AND ".join(conditions) if conditions else ""
        db = self.server.connect_db()
        try:
            db.execute("BEGIN")
            total = db.execute("SELECT COUNT(*) " + ITEM_FROM + where, args).fetchone()[0]
            rows = db.execute(ITEM_SELECT + ITEM_FROM + where + " ORDER BY items.created_at DESC,items.rowid DESC LIMIT ? OFFSET ?",
                              [*args, limit, offset]).fetchall()
            return {"items": [self.serialize_item(row) for row in rows], "total": total, "offset": offset, "limit": limit}
        finally:
            db.close()

    def overview(self, tls_enabled):
        server = self.server
        # Recover abandoned software intents without ever emitting a GPIO pulse.
        snapshot = server.lockers.snapshot()
        device, metrics = self.telemetry.sample()
        levels = gpio_levels(snapshot["driver"] == "gpio")
        db = server.connect_db()
        try:
            db.execute("BEGIN")
            manual = [lockers.manual_operation_json(row) for row in db.execute(
                "SELECT * FROM manual_openings WHERE state!='completed' ORDER BY created_at,id")]
            snapshot["operations"] = [server.lockers.operation_json(row) for row in db.execute(
                "SELECT * FROM locker_operations WHERE state!='completed' ORDER BY created_at,id")]
            counts = dict(db.execute("SELECT COALESCE(item_storage.status,'recorded'),COUNT(*) FROM items "
                                     "LEFT JOIN item_storage ON item_storage.item_id=items.id GROUP BY 1").fetchall())
            jobs = dict(db.execute("SELECT state,COUNT(*) FROM recognition_jobs GROUP BY state").fetchall())
            pulses = dict(db.execute("SELECT compartment_id,attempted_at FROM locker_pulses").fetchall())
            # Read the slot rows and attached inventory in the same DB snapshot.
            snapshot["compartments"] = [dict(row) for row in db.execute("SELECT id,state,item_id FROM compartments ORDER BY id")]
            for slot in snapshot["compartments"]:
                slot["door"] = server.lockers.door_snapshot(slot["id"])
                gpio = lockers.GPIO_MAP[slot["id"]]
                latest = pulses.get(slot["id"], 0)
                if snapshot["driver"] == "gpio":
                    try:
                        latest = max(latest, float(read_text(server.db_path.parent / f"lock-test-gpio{gpio}.lock")))
                    except ValueError:
                        pass
                cooldown = server.lockers.driver.cooldown_seconds if server.lockers.driver else 0
                row = db.execute(ITEM_SELECT + ITEM_FROM + " WHERE items.id=?", (slot["item_id"],)).fetchone() if slot["item_id"] else None
                slot.update(gpio=gpio, pin=PHYSICAL_PINS[slot["id"]], output_level=levels.get(gpio),
                            cooldown_remaining_seconds=round(max(0, cooldown - (time.time() - latest)), 1),
                            door_state=slot["door"]["state"], item=self.serialize_item(row) if row else None)
            activity = [dict(row) for row in db.execute("""SELECT id,kind AS type,compartment_id,item_id,state,created_at,
                NULL AS reason,error FROM locker_operations UNION ALL
                SELECT id,'manual' AS type,compartment_id,item_id,state,created_at,reason,error FROM manual_openings
                ORDER BY created_at DESC LIMIT 50""")]
        finally:
            db.close()
        with server.ai_lock:
            pending_count = len(server.ai_pending)
        return {"generated_at": utc_now(), "refresh_interval_seconds": 3, "device": device, "metrics": metrics,
                "services": {"api": "online", "database": "online", "tls_enabled": tls_enabled,
                             "recognition": {"configured": vision.configuration_status()["configured"],
                                             "queue_depth": server.ai_queue.qsize(), "pending_count": pending_count}},
                "inventory": {"total": sum(counts.values()), "stored": counts.get("stored", 0),
                              "collected": counts.get("collected", 0), "recorded": counts.get("recorded", 0),
                              "pending": counts.get("deposit_pending", 0) + counts.get("retrieval_pending", 0),
                              "recovery": counts.get("recovery", 0),
                              "recognition_pending": jobs.get("pending", 0) + jobs.get("processing", 0),
                              "recognition_failed": jobs.get("failed", 0)},
                "lockers": snapshot, "manual_operations": manual, "activity": activity,
                "vibration": server.vibration.snapshot(),
                "capabilities": {"door_sensor": server.door_feedback.enabled,
                                 "physical_feedback": server.door_feedback.enabled,
                                 "vibration_sensor": server.vibration.enabled}}
