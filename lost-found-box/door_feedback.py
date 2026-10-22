"""Read the compartment 01 and 02 dry-contact inputs without driving any GPIO output."""

from dataclasses import dataclass
import importlib
import threading
import time


INPUTS = {"01": (12, 32), "02": (18, 12)}
POLL_SECONDS = 0.05
DEBOUNCE_SECONDS = 0.25
STALE_SECONDS = 1.0


def not_configured():
    return {"enabled": False, "gpio": None, "pin": None, "state": "not_configured",
            "level": None, "updated_at": None, "error": None}


@dataclass
class DoorInput:
    gpio: int
    pin: int
    level: int | None = None
    candidate_since: float | None = None
    last_sample: float | None = None
    updated_at: float | None = None
    stable: bool = False
    error: str | None = None


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
        self._inputs = {slot: DoorInput(*pins) for slot, pins in INPUTS.items()}

    def start(self):
        if self._started or self._closed or not self.enabled:
            return
        self._started = True
        try:
            if self._api is None:
                self._api = importlib.import_module("lgpio")
            self._handle = self._api.gpiochip_open(0)
            for slot, sensor in self._inputs.items():
                try:
                    self._api.gpio_claim_input(self._handle, sensor.gpio, lFlags=self._api.SET_PULL_UP)
                except Exception:
                    self._fail(slot)
            self._sample()
            if self._stop.is_set():
                self._release_gpio()
                return
            self._thread = threading.Thread(target=self._run, name="door-feedback", daemon=True)
            self._thread.start()
        except Exception:
            self._fail()
            self._release_gpio()

    def _sample(self):
        for slot, sensor in self._inputs.items():
            if sensor.error:
                continue
            try:
                level = self._api.gpio_read(self._handle, sensor.gpio)
                if level not in (0, 1):
                    raise RuntimeError("Invalid door input level")
                now = self._clock()
                with self._lock:
                    # Each contact debounces independently; a transition must
                    # immediately invalidate only that contact's closed state.
                    if (level != sensor.level or sensor.last_sample is None
                            or now - sensor.last_sample >= STALE_SECONDS):
                        sensor.candidate_since = now
                        sensor.stable = False
                    sensor.level = level
                    sensor.last_sample = now
                    sensor.updated_at = self._wall_clock()
                    if now - sensor.candidate_since >= DEBOUNCE_SECONDS - 1e-9:
                        sensor.stable = True
            except Exception:
                self._fail(slot)

    def _run(self):
        try:
            while not self._stop.wait(POLL_SECONDS):
                self._sample()
        except Exception:
            self._fail()
        finally:
            self._release_gpio()

    def _fail(self, compartment=None):
        with self._lock:
            for slot, sensor in self._inputs.items():
                if compartment is None or slot == compartment:
                    sensor.error = f"Door sensor unavailable. Check compartment {slot} and GPIO{sensor.gpio}."
                    sensor.level = None
                    sensor.stable = False
            if all(sensor.error for sensor in self._inputs.values()):
                self._stop.set()

    def snapshot(self, compartment):
        if not self.enabled or compartment not in self._inputs:
            return not_configured()
        with self._lock:
            sensor = self._inputs[compartment]
            stale = sensor.last_sample is not None and self._clock() - sensor.last_sample >= STALE_SECONDS
            error = sensor.error
            if self._closed or stale:
                error = "Door sensor data is unavailable. Wait for monitoring to resume."
            state = ("unavailable" if error else "unknown" if not sensor.stable
                     else "closed" if sensor.level == 0 else "open")
            return {"enabled": True, "gpio": sensor.gpio, "pin": sensor.pin,
                    "state": state, "level": None if error else sensor.level,
                    "updated_at": sensor.updated_at, "error": error}

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
            for sensor in self._inputs.values():
                sensor.stable = False
                sensor.level = None
