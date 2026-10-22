"""Continuous GPIO21 vibration input and a small persistent alert history."""

from collections import deque
import importlib
import math
import queue
import threading
import time
import uuid

import vision


GPIO = 21
PHYSICAL_PIN = 40
WINDOW_SECONDS = 2.0
THRESHOLD = 5
DEBOUNCE_SECONDS = 0.1
QUEUE_SIZE = 1024


class VibrationMonitor:
    def __init__(self, connect, enabled=False, api=None, *, clock=time.monotonic,
                 wall_clock=time.time):
        self.connect = connect
        self.enabled = enabled
        self._api = api
        self._clock = clock
        self._wall_clock = wall_clock
        self._lock = threading.RLock()
        self._resources = threading.Lock()
        self._queue = queue.Queue(maxsize=QUEUE_SIZE)
        self._stop = threading.Event()
        self._overflow = threading.Event()
        self._thread = None
        self._handle = None
        self._callback = None
        self._started = False
        self._closed = False
        self._input_level = None
        self._edge_level = None
        self._timestamp_origin = None
        self._timestamp_offset = None
        self._last_accepted = None
        self._count_after = float("-inf")
        self._suppressed_until = float("-inf")
        self._recent = deque()
        self._total = 0
        self._last_triggered_at = None
        self._error = None
        self._active = None
        self._events = []
        db = self.connect()
        try:
            with db:
                db.executescript("""
                    CREATE TABLE IF NOT EXISTS vibration_alerts (
                        id TEXT PRIMARY KEY,
                        triggered_at REAL NOT NULL,
                        trigger_count INTEGER NOT NULL,
                        cleared_at REAL
                    );
                    CREATE UNIQUE INDEX IF NOT EXISTS vibration_one_active
                        ON vibration_alerts((1)) WHERE cleared_at IS NULL;
                """)
            self._load_history(db)
        finally:
            db.close()

    @staticmethod
    def _alert(row):
        return dict(zip(("id", "triggered_at", "trigger_count", "cleared_at"), row)) if row else None

    def _load_history(self, db):
        fields = "id,triggered_at,trigger_count,cleared_at"
        self._active = self._alert(db.execute(
            f"SELECT {fields} FROM vibration_alerts WHERE cleared_at IS NULL").fetchone())
        self._events = [self._alert(row) for row in db.execute(
            f"SELECT {fields} FROM vibration_alerts ORDER BY triggered_at DESC,rowid DESC LIMIT 20")]

    def start(self):
        """Claim only the sensor input; GPIO failures remain visible in snapshot()."""
        if self._started or self._closed or not self.enabled:
            return
        self._started = True
        try:
            if self._api is None:
                self._api = importlib.import_module("lgpio")
            self._handle = self._api.gpiochip_open(0)
            self._api.gpio_claim_alert(self._handle, GPIO, self._api.BOTH_EDGES,
                                       lFlags=self._api.SET_PULL_NONE)
            self._callback = self._api.callback(self._handle, GPIO,
                                                self._api.BOTH_EDGES, self._on_edge)
            self._read_input()
            self._thread = threading.Thread(target=self._run, name="vibration-monitor", daemon=True)
            self._thread.start()
        except Exception:
            self._fail("Vibration sensor unavailable. Check GPIO21 and its connection.")
            self._release_gpio()

    def _on_edge(self, chip, gpio, level, timestamp):
        # Capture short pulses immediately. Stable-level GPIO debounce would erase them.
        if gpio != GPIO or level not in (0, 1) or self._stop.is_set():
            return
        try:
            self._queue.put_nowait((level, timestamp, self._clock(), self._wall_clock()))
        except queue.Full:
            self._overflow.set()

    def _run(self):
        next_read = self._clock() + 1
        try:
            while not self._stop.is_set():
                if self._overflow.is_set():
                    self._fail("Vibration input overloaded. Restart monitoring after checking the sensor.")
                    break
                try:
                    edge = self._queue.get(timeout=0.1)
                except queue.Empty:
                    edge = None
                if edge is not None:
                    try:
                        self._process_edge(*edge)
                    finally:
                        self._queue.task_done()
                if self._clock() >= next_read:
                    self._read_input()
                    next_read = self._clock() + 1
        except Exception:
            self._fail("Vibration monitoring stopped. Check the sensor and restart monitoring.")
        finally:
            self._release_gpio()
            while True:
                try:
                    self._queue.get_nowait()
                except queue.Empty:
                    break
                self._queue.task_done()

    def _read_input(self):
        level = self._api.gpio_read(self._handle, GPIO)
        if level not in (0, 1):
            raise RuntimeError("Invalid GPIO input level")
        with self._lock:
            self._input_level = level

    def _fail(self, message):
        with self._lock:
            self._error = message
            self._input_level = None
        self._stop.set()

    def _process_edge(self, level, timestamp, received_at, wall_time):
        with self._lock:
            self._input_level = level
            previous = self._edge_level
            self._edge_level = level
            # lgpio timestamps have an unspecified origin. Anchor their differences
            # to monotonic receipt time instead of comparing them with Unix time.
            event_time = received_at
            if isinstance(timestamp, int) and timestamp >= 0:
                if self._timestamp_origin is None:
                    self._timestamp_origin = timestamp
                seconds = (timestamp - self._timestamp_origin) / 1_000_000_000
                offset = received_at - seconds
                if self._timestamp_offset is None:
                    self._timestamp_offset = offset
                elif offset < self._timestamp_offset:
                    # A batch may arrive together. Move earlier captured edges
                    # with its clock anchor, preserving their real spacing.
                    shift = offset - self._timestamp_offset
                    self._recent = deque(value + shift for value in self._recent)
                    if self._last_accepted is not None:
                        self._last_accepted += shift
                    self._timestamp_offset = offset
                event_time = seconds + self._timestamp_offset
            if (level != 1 or previous == 1 or received_at <= self._count_after
                    or event_time <= self._count_after):
                return
            if (self._last_accepted is not None
                    and event_time - self._last_accepted < DEBOUNCE_SECONDS - 1e-9):
                return
            self._last_accepted = event_time
            self._recent.append(event_time)
            self._trim(event_time)
            self._total += 1
            self._last_triggered_at = wall_time + (event_time - received_at)
            if len(self._recent) >= THRESHOLD and self._active is None:
                self._record_alert(self._last_triggered_at)

    def _trim(self, now):
        while self._recent and self._recent[0] < now - WINDOW_SECONDS:
            self._recent.popleft()

    def _record_alert(self, wall_time):
        db = self.connect()
        try:
            with db:
                db.execute("INSERT OR IGNORE INTO vibration_alerts VALUES(?,?,?,NULL)",
                           (str(uuid.uuid4()), wall_time, len(self._recent)))
                db.execute("""DELETE FROM vibration_alerts WHERE id NOT IN (
                    SELECT id FROM vibration_alerts
                    ORDER BY (cleared_at IS NULL) DESC,triggered_at DESC,rowid DESC LIMIT 100
                )""")
            self._load_history(db)
        finally:
            db.close()

    def snapshot(self):
        with self._lock:
            now = self._clock()
            self._trim(now)
            status = ("disabled" if not self.enabled or self._closed else "error" if self._error
                      else "alert" if self._active else "monitoring")
            return {
                "enabled": self.enabled and not self._closed,
                "status": status,
                "gpio": GPIO,
                "pin": PHYSICAL_PIN,
                "active_level": 1,
                "input_level": self._input_level,
                "window_seconds": WINDOW_SECONDS,
                "threshold": THRESHOLD,
                "debounce_ms": round(DEBOUNCE_SECONDS * 1000),
                "suppressed": self.enabled and not self._closed and now < self._suppressed_until,
                "recent_triggers": len(self._recent),
                "total_triggers": self._total,
                "last_triggered_at": self._last_triggered_at,
                "active_alert": dict(self._active) if self._active else None,
                "events": [dict(alert) for alert in self._events],
                "error": self._error,
            }

    def suppress_for(self, seconds):
        if not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or seconds < 0:
            raise ValueError("Suppression must be a finite nonnegative duration")
        with self._lock:
            self._suppressed_until = max(self._suppressed_until, self._clock() + seconds)
            self._count_after = max(self._count_after, self._suppressed_until)
            self._recent.clear()
            self._last_accepted = None

    def clear_alert(self, alert_id):
        if not isinstance(alert_id, str):
            raise vision.VisionError(400, "Choose a valid vibration alert.")
        try:
            if str(uuid.UUID(alert_id)) != alert_id:
                raise ValueError()
        except (ValueError, AttributeError):
            raise vision.VisionError(400, "Choose a valid vibration alert.") from None
        with self._lock:
            db = self.connect()
            try:
                with db:
                    db.execute("BEGIN IMMEDIATE")
                    target = db.execute("SELECT cleared_at FROM vibration_alerts WHERE id=?",
                                        (alert_id,)).fetchone()
                    if target is None:
                        raise vision.VisionError(404, "Vibration alert not found.")
                    active = db.execute("SELECT id FROM vibration_alerts WHERE cleared_at IS NULL").fetchone()
                    if active and active[0] != alert_id:
                        raise vision.VisionError(409, "A newer vibration alert is active. Refresh and try again.")
                    if target[0] is None:
                        db.execute("UPDATE vibration_alerts SET cleared_at=? WHERE id=?",
                                   (self._wall_clock(), alert_id))
                if target[0] is None:
                    self._recent.clear()
                    self._last_accepted = None
                    self._count_after = max(self._count_after, self._clock())
                self._load_history(db)
            finally:
                db.close()
            return self.snapshot()

    def _release_gpio(self):
        with self._resources:
            callback, self._callback = self._callback, None
            handle, self._handle = self._handle, None
            if callback is not None:
                try:
                    callback.cancel()
                except Exception:
                    pass
            if handle is not None:
                try:
                    self._api.gpiochip_close(handle)
                except Exception:
                    pass

    def close(self):
        self._stop.set()
        if (self._thread is not None and self._thread.ident is not None
                and self._thread is not threading.current_thread()):
            self._thread.join()
        self._release_gpio()
        with self._lock:
            self._closed = True
            self._input_level = None
