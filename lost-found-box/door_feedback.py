"""Read the compartment 01 dry-contact input without driving any GPIO output."""

import importlib
import threading
import time


GPIO = 12
PHYSICAL_PIN = 32
POLL_SECONDS = 0.05
DEBOUNCE_SECONDS = 0.25
STALE_SECONDS = 1.0


def not_configured():
    return {"enabled": False, "gpio": None, "pin": None, "state": "not_configured",
            "level": None, "updated_at": None, "error": None}


class DoorFeedbackMonitor:
    def __init__(self, enabled=False, api=None, *, clock=time.monotonic, wall_clock=time.time):
        self.enabled = enabled
        self._api = api
        self._clock = clock
        self._wall_clock = wall_clock
        self._lock = threading.Lock()
        self._resources = threading.Lock()
        self._stop = threading.Event()
        self._thread = None
        self._handle = None
        self._started = False
        self._closed = False
        self._level = None
        self._candidate_since = None
        self._last_sample = None
        self._updated_at = None
        self._stable = False
        self._error = None

    def start(self):
        if self._started or self._closed or not self.enabled:
            return
        self._started = True
        try:
            if self._api is None:
                self._api = importlib.import_module("lgpio")
            self._handle = self._api.gpiochip_open(0)
            self._api.gpio_claim_input(self._handle, GPIO, lFlags=self._api.SET_PULL_UP)
            self._sample()
            self._thread = threading.Thread(target=self._run, name="door-feedback", daemon=True)
            self._thread.start()
        except Exception:
            self._fail()
            self._release_gpio()

    def _sample(self):
        level = self._api.gpio_read(self._handle, GPIO)
        if level not in (0, 1):
            raise RuntimeError("Invalid door input level")
        now = self._clock()
        with self._lock:
            # A transition or a gap in sampling invalidates the previous closed
            # state immediately; only uninterrupted stable samples confirm it.
            if (level != self._level or self._last_sample is None
                    or now - self._last_sample >= STALE_SECONDS):
                self._candidate_since = now
                self._stable = False
            self._level = level
            self._last_sample = now
            self._updated_at = self._wall_clock()
            if now - self._candidate_since >= DEBOUNCE_SECONDS - 1e-9:
                self._stable = True

    def _run(self):
        try:
            while not self._stop.wait(POLL_SECONDS):
                self._sample()
        except Exception:
            self._fail()
        finally:
            self._release_gpio()

    def _fail(self):
        with self._lock:
            self._error = "Door sensor unavailable. Check compartment 01 and GPIO12."
            self._level = None
            self._stable = False
        self._stop.set()

    def snapshot(self, compartment):
        if not self.enabled or compartment != "01":
            return not_configured()
        with self._lock:
            stale = self._last_sample is not None and self._clock() - self._last_sample >= STALE_SECONDS
            error = self._error
            if self._closed or stale:
                error = "Door sensor data is unavailable. Wait for monitoring to resume."
            state = ("unavailable" if error else "unknown" if not self._stable
                     else "closed" if self._level == 0 else "open")
            return {"enabled": True, "gpio": GPIO, "pin": PHYSICAL_PIN,
                    "state": state, "level": None if error else self._level,
                    "updated_at": self._updated_at, "error": error}

    def _release_gpio(self):
        with self._resources:
            handle, self._handle = self._handle, None
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
            self._stable = False
            self._level = None
