"""Durable four-compartment workflows; hardware is disabled unless explicitly enabled.

A committed actuation is never replayed. Visitor item transfers need confirmation;
manual commands leave inventory unchanged and complete when the pulse finishes.
"""

from contextlib import ExitStack, contextmanager
import fcntl
import ipaddress
import os
from pathlib import Path
import threading
import time
import uuid

import vision

GPIO_MAP = {"01": 17, "02": 26, "03": 13, "04": 5}
UNCERTAIN = "Opening could not be confirmed. Keep this compartment reserved and ask staff to check it."


def canonical_uuid(value):
    try:
        if not isinstance(value, str) or str(uuid.UUID(value)) != value:
            raise ValueError()
        return value
    except ValueError:
        raise vision.VisionError(400, "A canonical UUID is required.") from None


def operation_json(row):
    return {key: row[key] for key in
            ("id", "kind", "item_id", "compartment_id", "state", "error")}


def manual_operation_json(row):
    return {key: row[key] for key in
            ("id", "compartment_id", "state", "reason", "created_at", "error", "item_id")}


class SimulatedDriver:
    name = "simulated"
    cooldown_seconds = 0

    def preflight(self):
        pass

    def pulse(self, compartment):
        pass


class GPIODriver:
    name = "gpio"
    cooldown_seconds = 30

    def __init__(self, mapping, api=None):
        if mapping != GPIO_MAP:
            raise ValueError("Confirm BCM mapping 01=17,02=26,03=13,04=5 before enabling GPIO.")
        self.mapping = dict(mapping)
        # Import only in explicit hardware mode. Development tests never import lgpio.
        if api is None:
            try:
                import lgpio as api
            except ImportError:
                raise ValueError("GPIO mode requires the Raspberry Pi lgpio package.") from None
        self.api = api
        self.api.exceptions = True

    def _inspect(self, handle):
        api = self.api
        if api.gpio_get_chip_info(handle)[3] != "pinctrl-bcm2711":
            raise RuntimeError("Expected Raspberry Pi 4B gpiochip0.")
        for gpio in self.mapping.values():
            line = api.gpio_get_line_info(handle, gpio)
            if line[3] != f"GPIO{gpio}" or line[4]:
                raise RuntimeError("A configured GPIO is unavailable.")

    def preflight(self):
        handle = self.api.gpiochip_open(0)
        try:
            self._inspect(handle)
        finally:
            self.api.gpiochip_close(handle)

    def pulse(self, compartment):
        api, gpio = self.api, self.mapping[compartment]
        handle = api.gpiochip_open(0)
        claimed = False
        try:
            self._inspect(handle)
            api.gpio_claim_output(handle, gpio, 0, api.SET_PULL_DOWN)
            claimed = True
            api.tx_pulse(handle, gpio, 500_000, 50_000, 0, 1)
            started, saw_high = time.monotonic(), False
            while api.tx_busy(handle, gpio, api.TX_PWM):
                if time.monotonic() - started > 1.5:
                    raise TimeoutError("Opening pulse did not finish.")
                saw_high = api.gpio_read(handle, gpio) == 1 or saw_high
                time.sleep(0.005)
            api.gpio_write(handle, gpio, 0)
            if api.gpio_read(handle, gpio) != 0 or not saw_high:
                raise RuntimeError("Opening pulse could not be verified.")
        finally:
            try:
                if claimed:
                    try:
                        try:
                            api.tx_pulse(handle, gpio, 0, 0, 0, 1)
                        except api.error as error:
                            if error.value != api.error_text(api.BAD_PWM_MICROS):
                                raise
                    finally:
                        try:
                            api.gpio_write(handle, gpio, 0)
                        finally:
                            api.gpio_free(handle, gpio)
            finally:
                api.gpiochip_close(handle)


def configured_driver(host, mode=None, mapping=None):
    mode = mode if mode is not None else os.environ.get("LOST_FOUND_LOCKER_MODE", "disabled")
    if mode == "disabled":
        return None
    if mode == "simulated":
        try:
            local = ipaddress.ip_address(host).is_loopback
        except ValueError:
            local = host.lower() == "localhost"
        if not local:
            raise ValueError("Simulated lockers may only listen on localhost.")
        return SimulatedDriver()
    if mode != "gpio":
        raise ValueError("LOST_FOUND_LOCKER_MODE must be disabled, simulated or gpio.")
    if mapping is None:
        try:
            pairs = [part.split("=") for part in os.environ.get("LOST_FOUND_LOCKER_GPIO_MAP", "").split(",")]
            mapping = {key.strip(): int(value) for key, value in pairs}
            if len(pairs) != 4:
                raise ValueError()
        except (ValueError, TypeError):
            raise ValueError("Set LOST_FOUND_LOCKER_GPIO_MAP=01=17,02=26,03=13,04=5 explicitly.") from None
    return GPIODriver(mapping)


class LockerStore:
    def __init__(self, connect, data_dir, driver=None):
        self.connect = connect
        self.directory = Path(data_dir)
        self.driver = driver
        self.enabled = driver is not None
        self.lock = threading.RLock()
        with self._serialized():
            db = self.connect()
            try:
                with db:
                    db.executescript("""
                    CREATE TABLE IF NOT EXISTS compartments (
                        id TEXT PRIMARY KEY CHECK(id IN ('01','02','03','04')),
                        state TEXT NOT NULL DEFAULT 'free', item_id TEXT UNIQUE REFERENCES items(id));
                    CREATE TABLE IF NOT EXISTS item_storage (
                        item_id TEXT PRIMARY KEY REFERENCES items(id), status TEXT NOT NULL,
                        compartment_id TEXT REFERENCES compartments(id));
                    CREATE TABLE IF NOT EXISTS locker_operations (
                        id TEXT PRIMARY KEY, kind TEXT NOT NULL, item_id TEXT NOT NULL REFERENCES items(id),
                        compartment_id TEXT NOT NULL REFERENCES compartments(id), state TEXT NOT NULL,
                        error TEXT, outcome TEXT, created_at REAL NOT NULL);
                    CREATE UNIQUE INDEX IF NOT EXISTS one_active_item_operation
                        ON locker_operations(item_id) WHERE state != 'completed';
                    CREATE UNIQUE INDEX IF NOT EXISTS one_active_compartment_operation
                        ON locker_operations(compartment_id) WHERE state != 'completed';
                    CREATE TABLE IF NOT EXISTS locker_pulses (
                        compartment_id TEXT PRIMARY KEY REFERENCES compartments(id), attempted_at REAL NOT NULL);
                    CREATE TABLE IF NOT EXISTS manual_openings (
                        id TEXT PRIMARY KEY, compartment_id TEXT NOT NULL REFERENCES compartments(id),
                        reason TEXT NOT NULL, created_at REAL NOT NULL, state TEXT NOT NULL, error TEXT,
                        item_id TEXT REFERENCES items(id), previous_slot_state TEXT NOT NULL,
                        previous_item_status TEXT, previous_item_compartment_id TEXT REFERENCES compartments(id),
                        previous_operation_id TEXT REFERENCES locker_operations(id), previous_operation_state TEXT);
                    CREATE UNIQUE INDEX IF NOT EXISTS one_active_manual_compartment
                        ON manual_openings(compartment_id) WHERE state!='completed';
                    CREATE UNIQUE INDEX IF NOT EXISTS one_active_manual_item
                        ON manual_openings(item_id) WHERE state!='completed' AND item_id IS NOT NULL;
                    """)
                    db.executemany("INSERT OR IGNORE INTO compartments(id) VALUES (?)", [(key,) for key in GPIO_MAP])
                    interrupted = db.execute("SELECT * FROM locker_operations WHERE state='actuating'").fetchall()
                    for row in interrupted:
                        self._uncertain(db, row["id"], row["item_id"], row["compartment_id"])
                    for row in db.execute("SELECT id FROM manual_openings WHERE state='actuating'").fetchall():
                        self._manual_uncertain(db, row["id"])
            finally:
                db.close()

    @contextmanager
    def _serialized(self):
        # Inter-thread and inter-process exclusion extends across the physical pulse.
        with self.lock:
            with (self.directory / "locker-hardware.lock").open("a+") as stream:
                fcntl.flock(stream, fcntl.LOCK_EX)
                try:
                    with ExitStack() as diagnostics:
                        # The standalone lock-1 tool uses these same file locks.
                        # Hold all four while issuing any station command.
                        if self.driver is not None and self.driver.name == "gpio":
                            for gpio in GPIO_MAP.values():
                                diagnostic = diagnostics.enter_context(
                                    (self.directory / f"lock-test-gpio{gpio}.lock").open("a+"))
                                fcntl.flock(diagnostic, fcntl.LOCK_EX)
                        yield
                finally:
                    fcntl.flock(stream, fcntl.LOCK_UN)

    def _recover_abandoned_locked(self):
        # Caller owns the hardware lock, so no other process can still be pulsing.
        db = self.connect()
        try:
            with db:
                db.execute("BEGIN IMMEDIATE")
                for row in db.execute("SELECT * FROM locker_operations WHERE state='actuating'").fetchall():
                    self._uncertain(db, row["id"], row["item_id"], row["compartment_id"])
                for row in db.execute("SELECT id FROM manual_openings WHERE state='actuating'").fetchall():
                    self._manual_uncertain(db, row["id"])
        finally:
            db.close()

    @contextmanager
    def _try_hardware_lock(self):
        if not self.lock.acquire(blocking=False):
            yield False
            return
        try:
            with (self.directory / "locker-hardware.lock").open("a+") as stream:
                try:
                    fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    yield False
                    return
                try:
                    yield True
                finally:
                    fcntl.flock(stream, fcntl.LOCK_UN)
        finally:
            self.lock.release()

    def _recover_if_idle(self):
        # Reads and completion must not wait for or interrupt an active pulse.
        # They can repair a committed intent whose owning request has exited.
        with self._try_hardware_lock() as acquired:
            if acquired:
                self._recover_abandoned_locked()

    def _cooling_down(self, db, compartment):
        row = db.execute("SELECT attempted_at FROM locker_pulses WHERE compartment_id=?", (compartment,)).fetchone()
        last = row[0] if row else 0
        diagnostic = self.directory / f"lock-test-gpio{GPIO_MAP[compartment]}.lock"
        if self.driver.name == "gpio" and diagnostic.exists():
            try:
                last = max(last, float(diagnostic.read_text().strip() or 0))
            except (OSError, ValueError):
                raise vision.VisionError(503, "Could not verify the lock cooldown. Ask staff to check it.") from None
        return time.time() - last < self.driver.cooldown_seconds

    def _issue_pulse(self, compartment):
        if self.driver.name == "gpio":
            # Keep the diagnostic CLI's cooldown in sync with the API.
            diagnostic = self.directory / f"lock-test-gpio{GPIO_MAP[compartment]}.lock"
            with diagnostic.open("w") as stream:
                stream.write(str(time.time()))
                stream.flush()
                os.fsync(stream.fileno())
        self.driver.pulse(compartment)

    def snapshot(self):
        self._recover_if_idle()
        db = self.connect()
        try:
            db.execute("BEGIN")
            compartments = [dict(row) for row in db.execute("SELECT id,state,item_id FROM compartments ORDER BY id")]
            operations = [operation_json(row) for row in db.execute(
                "SELECT * FROM locker_operations WHERE state!='completed' ORDER BY created_at,id")]
            return {"enabled": self.enabled, "driver": self.driver.name if self.driver else "disabled",
                    "compartments": compartments, "operations": operations}
        finally:
            db.close()

    def get(self, identifier):
        canonical_uuid(identifier)
        self._recover_if_idle()
        db = self.connect()
        try:
            row = db.execute("SELECT * FROM locker_operations WHERE id=?", (identifier,)).fetchone()
            if row is None:
                raise vision.VisionError(404, "Locker operation not found.")
            return operation_json(row)
        finally:
            db.close()

    @staticmethod
    def _uncertain(db, identifier, item_id, compartment):
        db.execute("UPDATE locker_operations SET state='uncertain',error=? WHERE id=?", (UNCERTAIN, identifier))
        db.execute("UPDATE item_storage SET status='recovery' WHERE item_id=?", (item_id,))
        db.execute("UPDATE compartments SET state='recovery' WHERE id=?", (compartment,))

    @staticmethod
    def _manual_uncertain(db, identifier):
        # The committed maintenance reservation and previous state stay intact.
        db.execute("UPDATE manual_openings SET state='uncertain',error=? WHERE id=?", (UNCERTAIN, identifier))

    def start(self, request_id, item_id, kind):
        canonical_uuid(request_id)
        canonical_uuid(item_id)
        if kind not in ("deposit", "retrieve"):
            raise vision.VisionError(400, "Operation kind must be deposit or retrieve.")
        with self._serialized():
            self._recover_abandoned_locked()
            db = self.connect()
            try:
                with db:
                    db.execute("BEGIN IMMEDIATE")
                    existing = db.execute("SELECT * FROM locker_operations WHERE id=?", (request_id,)).fetchone()
                    if existing:
                        if existing["item_id"] != item_id or existing["kind"] != kind:
                            raise vision.VisionError(409, "This request ID belongs to a different operation.")
                        return operation_json(existing), True
                    if not self.enabled:
                        raise vision.VisionError(503, "Locker controls are disabled. Ask staff for assistance.")
                    item = db.execute("SELECT items.id,recognitions.result, item_storage.status,item_storage.compartment_id "
                                      "FROM items LEFT JOIN recognitions ON recognitions.item_id=items.id "
                                      "LEFT JOIN item_storage ON item_storage.item_id=items.id WHERE items.id=?", (item_id,)).fetchone()
                    if item is None:
                        raise vision.VisionError(404, "Item not found.")
                    if db.execute("SELECT 1 FROM manual_openings WHERE item_id=? AND state!='completed'", (item_id,)).fetchone():
                        raise vision.VisionError(409, "Staff are checking this compartment. Wait for the maintenance confirmation.")
                    if db.execute("SELECT 1 FROM locker_operations WHERE item_id=? AND state!='completed'", (item_id,)).fetchone():
                        raise vision.VisionError(409, "This item already has an unfinished locker operation. Resume it first.")
                    if kind == "deposit":
                        if item["status"] not in (None, "recorded"):
                            raise vision.VisionError(409, "This item cannot be deposited again.")
                        if vision.cached_recognition(item["result"]) is None:
                            raise vision.VisionError(409, "Finish recognizing the item before assigning a compartment.")
                        free_slots = db.execute("SELECT * FROM compartments WHERE state='free' AND item_id IS NULL ORDER BY id").fetchall()
                        if not free_slots:
                            raise vision.VisionError(409, "All four compartments are in use. Ask staff for assistance.")
                        slot = next((candidate for candidate in free_slots if not self._cooling_down(db, candidate["id"])), None)
                        if slot is None:
                            raise vision.VisionError(429, "All free compartments are cooling down. Wait 30 seconds before trying again.")
                    else:
                        slot = db.execute("SELECT * FROM compartments WHERE id=? AND state='occupied' AND item_id=?",
                                          (item["compartment_id"], item_id)).fetchone()
                        if item["status"] != "stored" or slot is None:
                            raise vision.VisionError(409, "This item is no longer available for collection.")
                        if self._cooling_down(db, slot["id"]):
                            raise vision.VisionError(429, "This lock is cooling down. Wait 30 seconds before trying again.")
                    compartment = slot["id"]
                    try:
                        self.driver.preflight()
                    except Exception:
                        raise vision.VisionError(503, "Lock hardware is unavailable. No opening command was sent.") from None
                    pending = "deposit_pending" if kind == "deposit" else "retrieval_pending"
                    state = "reserved" if kind == "deposit" else "retrieving"
                    db.execute("INSERT INTO locker_operations VALUES (?,?,?,?, 'actuating',NULL,NULL,?)",
                               (request_id, kind, item_id, compartment, time.time()))
                    db.execute("INSERT INTO item_storage VALUES (?,?,?) ON CONFLICT(item_id) DO UPDATE SET "
                               "status=excluded.status,compartment_id=excluded.compartment_id", (item_id, pending, compartment))
                    db.execute("UPDATE compartments SET state=?,item_id=? WHERE id=?", (state, item_id, compartment))
                    db.execute("INSERT INTO locker_pulses VALUES (?,?) ON CONFLICT(compartment_id) DO UPDATE SET "
                               "attempted_at=excluded.attempted_at", (compartment, time.time()))
                # Durable actuation intent has committed before crossing the GPIO boundary.
                try:
                    self._issue_pulse(compartment)
                    with db:
                        db.execute("UPDATE locker_operations SET state='awaiting_confirmation' WHERE id=?", (request_id,))
                except Exception:
                    # A failed post-pulse commit is physically ambiguous too. If
                    # even this write fails, a later idle request repairs it.
                    with db:
                        self._uncertain(db, request_id, item_id, compartment)
                return operation_json(db.execute("SELECT * FROM locker_operations WHERE id=?", (request_id,)).fetchone()), False
            finally:
                db.close()

    def finish(self, identifier, outcome=None):
        canonical_uuid(identifier)
        self._recover_if_idle()
        db = self.connect()
        try:
            with db:
                db.execute("BEGIN IMMEDIATE")
                row = db.execute("SELECT * FROM locker_operations WHERE id=?", (identifier,)).fetchone()
                if row is None:
                    raise vision.VisionError(404, "Locker operation not found.")
                default = "stored" if row["kind"] == "deposit" else "collected"
                chosen = default if outcome is None else outcome
                allowed = ("stored", "empty") if row["kind"] == "deposit" else ("collected", "stored")
                if chosen not in allowed:
                    raise vision.VisionError(400, "This resolution does not match the locker operation.")
                if row["state"] == "completed":
                    if row["outcome"] != chosen:
                        raise vision.VisionError(409, "A completed operation cannot be reinterpreted.")
                    return operation_json(row)
                allowed_states = ("awaiting_confirmation",) if outcome is None else ("awaiting_confirmation", "uncertain")
                if row["state"] not in allowed_states:
                    raise vision.VisionError(409, "This operation needs staff inspection before it can finish.")
                slot = db.execute("SELECT * FROM compartments WHERE id=?", (row["compartment_id"],)).fetchone()
                storage = db.execute("SELECT * FROM item_storage WHERE item_id=?", (row["item_id"],)).fetchone()
                expected_slot = "recovery" if row["state"] == "uncertain" else (
                    "reserved" if row["kind"] == "deposit" else "retrieving")
                expected_item = "recovery" if row["state"] == "uncertain" else (
                    "deposit_pending" if row["kind"] == "deposit" else "retrieval_pending")
                if (slot is None or slot["item_id"] != row["item_id"] or slot["state"] != expected_slot or
                        storage is None or storage["compartment_id"] != slot["id"] or storage["status"] != expected_item):
                    raise vision.VisionError(409, "Compartment ownership changed. Ask staff to check it.")
                occupied = chosen == "stored"
                item_status = "stored" if occupied else ("recorded" if chosen == "empty" else "collected")
                db.execute("UPDATE item_storage SET status=?,compartment_id=? WHERE item_id=?",
                           (item_status, slot["id"] if occupied else None, row["item_id"]))
                db.execute("UPDATE compartments SET state=?,item_id=? WHERE id=?",
                           ("occupied" if occupied else "free", row["item_id"] if occupied else None, slot["id"]))
                db.execute("UPDATE locker_operations SET state='completed',outcome=?,error=NULL WHERE id=?", (chosen, identifier))
                return operation_json(db.execute("SELECT * FROM locker_operations WHERE id=?", (identifier,)).fetchone())
        finally:
            db.close()

    def manual_open(self, request_id, compartment_id, reason=""):
        canonical_uuid(request_id)
        if not isinstance(compartment_id, str) or compartment_id not in GPIO_MAP:
            raise vision.VisionError(400, "Choose compartment 01, 02, 03 or 04.")
        if not isinstance(reason, str) or len(reason.strip()) > 200:
            raise vision.VisionError(400, "The reason must be text of up to 200 characters.")
        reason = reason.strip() or "Manual opening"
        try:
            reason.encode("utf-8")
        except UnicodeError:
            raise vision.VisionError(400, "Invalid reason text.") from None
        with self._serialized():
            self._recover_abandoned_locked()
            db = self.connect()
            try:
                with db:
                    db.execute("BEGIN IMMEDIATE")
                    existing = db.execute("SELECT * FROM manual_openings WHERE id=?", (request_id,)).fetchone()
                    if existing is not None:
                        if existing["compartment_id"] != compartment_id or existing["reason"] != reason:
                            raise vision.VisionError(409, "This request ID belongs to a different manual opening.")
                        return manual_operation_json(existing), True
                    if not self.enabled:
                        raise vision.VisionError(503, "Locker controls are disabled. No opening command was sent.")
                    if db.execute("SELECT 1 FROM manual_openings WHERE compartment_id=? AND state!='completed'",
                                  (compartment_id,)).fetchone():
                        raise vision.VisionError(409, "This compartment already has an unfinished manual opening.")
                    slot = db.execute("SELECT * FROM compartments WHERE id=?", (compartment_id,)).fetchone()
                    if slot is None:
                        raise vision.VisionError(409, "Compartment configuration is incomplete. No opening command was sent.")
                    visitor = db.execute("SELECT * FROM locker_operations WHERE compartment_id=? AND state!='completed'",
                                         (compartment_id,)).fetchone()
                    storage = db.execute("SELECT * FROM item_storage WHERE item_id=?", (slot["item_id"],)).fetchone()
                    expected_status = {"occupied": "stored", "reserved": "deposit_pending",
                                       "retrieving": "retrieval_pending", "recovery": "recovery"}
                    valid_visitor = visitor is None if slot["state"] in ("free", "occupied") else (
                        visitor is not None and visitor["item_id"] == slot["item_id"] and
                        ((slot["state"] == "reserved" and visitor["kind"] == "deposit" and visitor["state"] == "awaiting_confirmation") or
                         (slot["state"] == "retrieving" and visitor["kind"] == "retrieve" and visitor["state"] == "awaiting_confirmation") or
                         (slot["state"] == "recovery" and visitor["state"] == "uncertain")))
                    if slot["state"] == "free":
                        valid = slot["item_id"] is None and valid_visitor
                    else:
                        valid = (slot["state"] in expected_status and storage is not None and
                                 storage["status"] == expected_status[slot["state"]] and
                                 storage["compartment_id"] == compartment_id and valid_visitor)
                    if not valid:
                        raise vision.VisionError(409, "Compartment state is inconsistent. Inspect the existing operation first.")
                    if self._cooling_down(db, compartment_id):
                        raise vision.VisionError(429, "This lock is cooling down. Wait 30 seconds before trying again.")
                    try:
                        self.driver.preflight()
                    except Exception:
                        raise vision.VisionError(503, "Lock hardware is unavailable. No opening command was sent.") from None
                    db.execute("""INSERT INTO manual_openings
                        (id,compartment_id,reason,created_at,state,error,item_id,previous_slot_state,
                         previous_item_status,previous_item_compartment_id,previous_operation_id,previous_operation_state)
                        VALUES (?,?,?,?,'actuating',NULL,?,?,?,?,?,?)""",
                        (request_id, compartment_id, reason, time.time(), slot["item_id"], slot["state"],
                         storage["status"] if storage else None, storage["compartment_id"] if storage else None,
                         visitor["id"] if visitor else None, visitor["state"] if visitor else None))
                    db.execute("UPDATE compartments SET state='maintenance' WHERE id=?", (compartment_id,))
                    db.execute("INSERT INTO locker_pulses VALUES (?,?) ON CONFLICT(compartment_id) DO UPDATE SET "
                               "attempted_at=excluded.attempted_at", (compartment_id, time.time()))
                try:
                    self._issue_pulse(compartment_id)
                    with db:
                        db.execute("BEGIN IMMEDIATE")
                        row = db.execute("SELECT * FROM manual_openings WHERE id=?", (request_id,)).fetchone()
                        self._restore_manual(db, row)
                except Exception:
                    with db:
                        self._manual_uncertain(db, request_id)
                return manual_operation_json(db.execute("SELECT * FROM manual_openings WHERE id=?", (request_id,)).fetchone()), False
            finally:
                db.close()

    def manual_get(self, identifier):
        canonical_uuid(identifier)
        self._recover_if_idle()
        db = self.connect()
        try:
            row = db.execute("SELECT * FROM manual_openings WHERE id=?", (identifier,)).fetchone()
            if row is None:
                raise vision.VisionError(404, "Manual opening not found.")
            return manual_operation_json(row)
        finally:
            db.close()

    def manual_list(self):
        self._recover_if_idle()
        db = self.connect()
        try:
            return [manual_operation_json(row) for row in db.execute(
                "SELECT * FROM manual_openings WHERE state!='completed' ORDER BY created_at,id")]
        finally:
            db.close()

    @staticmethod
    def _restore_manual(db, row):
        # Caller owns the hardware lock and a write transaction. Completing the
        # command restores software availability without inferring item movement
        # or a measured door position.
        slot = db.execute("SELECT * FROM compartments WHERE id=?", (row["compartment_id"],)).fetchone()
        storage = db.execute("SELECT * FROM item_storage WHERE item_id=?", (row["item_id"],)).fetchone()
        visitor = db.execute("SELECT * FROM locker_operations WHERE compartment_id=? AND state!='completed'",
                             (row["compartment_id"],)).fetchone()
        valid_storage = (storage is None and row["item_id"] is None) or (
            storage is not None and storage["status"] == row["previous_item_status"] and
            storage["compartment_id"] == row["previous_item_compartment_id"])
        valid_visitor = (visitor is None and row["previous_operation_id"] is None) or (
            visitor is not None and visitor["id"] == row["previous_operation_id"] and
            visitor["state"] == row["previous_operation_state"] and visitor["item_id"] == row["item_id"])
        if (slot is None or slot["state"] != "maintenance" or slot["item_id"] != row["item_id"] or
                not valid_storage or not valid_visitor):
            raise vision.VisionError(409, "Compartment or item state changed. Check it before restoring availability.")
        db.execute("UPDATE compartments SET state=? WHERE id=?", (row["previous_slot_state"], row["compartment_id"]))
        db.execute("UPDATE manual_openings SET state='completed',error=NULL WHERE id=?", (row["id"],))

    def manual_confirm(self, identifier):
        canonical_uuid(identifier)
        # Recovery for interrupted commands and older pending confirmations.
        with self._try_hardware_lock() as acquired:
            if not acquired:
                raise vision.VisionError(409, "An opening command is in progress. Try again when it finishes.")
            self._recover_abandoned_locked()
            db = self.connect()
            try:
                with db:
                    db.execute("BEGIN IMMEDIATE")
                    row = db.execute("SELECT * FROM manual_openings WHERE id=?", (identifier,)).fetchone()
                    if row is None:
                        raise vision.VisionError(404, "Manual opening not found.")
                    if row["state"] == "completed":
                        return manual_operation_json(row)
                    if row["state"] not in ("awaiting_confirmation", "uncertain"):
                        raise vision.VisionError(409, "Wait for the opening command before checking the compartment.")
                    self._restore_manual(db, row)
                    return manual_operation_json(db.execute("SELECT * FROM manual_openings WHERE id=?", (identifier,)).fetchone())
            finally:
                db.close()
