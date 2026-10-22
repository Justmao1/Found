from pathlib import Path
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

import vibration
import vision


class FakeClock:
    def __init__(self):
        self.now = 10.0

    def __call__(self):
        return self.now

    def wall(self):
        return 1_800_000_000 + self.now

    def advance(self, seconds):
        self.now += seconds


class FakeGPIO:
    BOTH_EDGES = 3
    SET_PULL_NONE = 0

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.level = 0
        self.calls = []
        self.func = None
        self.failure = None
        self.cancelled = False
        self.closed = False

    def _call(self, name, *args):
        self.calls.append((name, *args))
        if self.failure == name:
            raise RuntimeError("fixture GPIO failure")

    def gpiochip_open(self, chip):
        self._call("open", chip)
        return 0

    def gpio_claim_alert(self, handle, gpio, edge, lFlags=0):
        self._call("claim_alert", handle, gpio, edge, lFlags)
        return 0

    def callback(self, handle, gpio, edge, func):
        self._call("callback", handle, gpio, edge)
        self.func = func
        return self

    def gpio_read(self, handle, gpio):
        self._call("read", handle, gpio)
        return self.level

    def emit(self, level, timestamp=None):
        self.level = level
        if self.func is not None and not self.cancelled:
            self.func(0, 21, level, timestamp if timestamp is not None else
                      9_000_000_000_000_000_000 + round(self.clock() * 1_000_000_000))

    def cancel(self):
        self._call("cancel")
        self.cancelled = True

    def gpiochip_close(self, handle):
        self._call("close", handle)
        self.closed = True


class VibrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / "items.sqlite3"
        self.clock = FakeClock()
        self.monitors = []

    def tearDown(self):
        for monitor in self.monitors:
            monitor.close()
        self.directory.cleanup()

    def connect(self):
        db = sqlite3.connect(self.path, timeout=2)
        db.row_factory = sqlite3.Row
        return db

    def monitor(self, enabled=True, start=True, api=None):
        api = api if api is not None else FakeGPIO(self.clock)
        monitor = vibration.VibrationMonitor(self.connect, enabled=enabled, api=api,
                                              clock=self.clock, wall_clock=self.clock.wall)
        self.monitors.append(monitor)
        if start:
            monitor.start()
        return monitor, api

    def pulse(self, monitor, api, delay=0.2, duration=0.002):
        self.clock.advance(delay)
        api.emit(1)
        self.clock.advance(duration)
        api.emit(0)
        monitor._queue.join()

    def trigger(self, monitor, api):
        for _ in range(5):
            self.pulse(monitor, api)
        return monitor.snapshot()["active_alert"]

    def wait(self, predicate):
        until = time.monotonic() + 2
        while not predicate() and time.monotonic() < until:
            time.sleep(0.005)
        self.assertTrue(predicate())

    def assert_error(self, code, function, *args):
        with self.assertRaises(vision.VisionError) as error:
            function(*args)
        self.assertEqual(error.exception.status, code)

    def test_disabled_schema_without_importing_or_claiming_gpio(self):
        with patch("vibration.importlib.import_module", side_effect=AssertionError("no import")):
            monitor = vibration.VibrationMonitor(self.connect)
            self.monitors.append(monitor)
            monitor.start()
        state = monitor.snapshot()
        self.assertEqual(state["status"], "disabled")
        self.assertFalse(state["enabled"])
        self.assertEqual((state["gpio"], state["pin"], state["active_level"]), (21, 40, 1))
        self.assertEqual((state["window_seconds"], state["threshold"], state["debounce_ms"]), (2, 5, 100))
        self.assertIsNone(state["input_level"])
        self.assertIsNone(state["last_triggered_at"])
        self.assertEqual(state["events"], [])

    def test_short_high_pulses_latch_once_at_five_and_input_remains_low(self):
        monitor, api = self.monitor()
        for _ in range(4):
            self.pulse(monitor, api)
        self.assertEqual(monitor.snapshot()["status"], "monitoring")
        self.pulse(monitor, api)
        first = monitor.snapshot()["active_alert"]
        self.assertEqual(first["trigger_count"], 5)
        for _ in range(10):
            self.pulse(monitor, api)
        state = monitor.snapshot()
        self.assertEqual(state["status"], "alert")
        self.assertEqual(state["active_alert"], first)
        self.assertEqual(len(state["events"]), 1)
        self.assertEqual(state["total_triggers"], 15)
        self.assertEqual(state["input_level"], 0)
        self.assertAlmostEqual(state["last_triggered_at"], self.clock.wall() - 0.002, delta=0.000001)

    def test_bounce_is_rejected_but_100ms_apart_pulses_count(self):
        monitor, api = self.monitor()
        self.pulse(monitor, api, delay=0)
        for _ in range(4):
            self.pulse(monitor, api, delay=0.008)
        self.assertEqual(monitor.snapshot()["total_triggers"], 1)
        self.pulse(monitor, api, delay=0.058)
        self.assertEqual(monitor.snapshot()["total_triggers"], 2)

    def test_duplicate_high_callbacks_do_not_count_as_new_pulses(self):
        monitor, api = self.monitor()
        for _ in range(6):
            self.clock.advance(0.2)
            api.emit(1)
        monitor._queue.join()
        self.assertEqual(monitor.snapshot()["total_triggers"], 1)
        self.assertIsNone(monitor.snapshot()["active_alert"])

    def test_sparse_vibrations_age_out_of_rolling_window(self):
        monitor, api = self.monitor()
        for _ in range(5):
            self.pulse(monitor, api, delay=0.6)
        state = monitor.snapshot()
        self.assertEqual(state["total_triggers"], 5)
        self.assertEqual(state["recent_triggers"], 4)
        self.assertIsNone(state["active_alert"])
        self.clock.advance(2.01)
        self.assertEqual(monitor.snapshot()["recent_triggers"], 0)

    def test_batched_callbacks_use_edge_spacing_with_unrelated_timestamp_origin(self):
        monitor, api = self.monitor()
        origin = 8_000_000_000_000_000_000
        for index in range(5):
            api.emit(1, origin + index * 200_000_000)
            api.emit(0, origin + index * 200_000_000 + 2_000_000)
        monitor._queue.join()
        self.assertEqual(monitor.snapshot()["total_triggers"], 5)
        self.assertIsNotNone(monitor.snapshot()["active_alert"])

    def test_delayed_old_events_are_not_turned_into_recent_burst(self):
        monitor, api = self.monitor()
        origin = 8_000_000_000_000_000_000
        for index in range(5):
            api.emit(1, origin + index * 600_000_000)
            api.emit(0, origin + index * 600_000_000 + 2_000_000)
        monitor._queue.join()
        self.assertEqual(monitor.snapshot()["total_triggers"], 5)
        self.assertIsNone(monitor.snapshot()["active_alert"])

    def test_clear_resets_window_rearms_and_rejects_stale_id(self):
        monitor, api = self.monitor()
        first = self.trigger(monitor, api)
        cleared = monitor.clear_alert(first["id"])
        self.assertEqual(cleared["status"], "monitoring")
        self.assertEqual(cleared["recent_triggers"], 0)
        self.assertIsNotNone(cleared["events"][0]["cleared_at"])
        self.assertEqual(monitor.clear_alert(first["id"]), cleared)
        second = self.trigger(monitor, api)
        self.assertNotEqual(second["id"], first["id"])
        self.assert_error(409, monitor.clear_alert, first["id"])
        self.assertEqual(monitor.snapshot()["active_alert"], second)

    def test_clear_validates_id_and_missing_alert(self):
        monitor, _ = self.monitor(enabled=False)
        for invalid in (None, 21, "", "not-an-id", str(uuid.uuid4()).upper()):
            self.assert_error(400, monitor.clear_alert, invalid)
        self.assert_error(404, monitor.clear_alert, str(uuid.uuid4()))

    def test_restart_restores_active_and_history_but_resets_session_counters(self):
        monitor, api = self.monitor()
        first = self.trigger(monitor, api)
        monitor.close()
        restored, _ = self.monitor()
        state = restored.snapshot()
        self.assertEqual(state["active_alert"], first)
        self.assertEqual(state["status"], "alert")
        self.assertEqual(state["total_triggers"], 0)
        self.assertEqual(state["recent_triggers"], 0)
        self.assertIsNone(state["last_triggered_at"])
        restored.clear_alert(first["id"])
        disabled, _ = self.monitor(enabled=False)
        self.assertIsNotNone(disabled.snapshot()["events"][0]["cleared_at"])

    def test_history_retains_100_and_exposes_only_20(self):
        monitor, api = self.monitor()
        for _ in range(105):
            alert = self.trigger(monitor, api)
            monitor.clear_alert(alert["id"])
        self.assertEqual(len(monitor.snapshot()["events"]), 20)
        db = self.connect()
        try:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM vibration_alerts").fetchone()[0], 100)
        finally:
            db.close()

    def test_suppression_ignores_lock_shocks_then_resumes_without_clearing_alert(self):
        monitor, api = self.monitor()
        for _ in range(4):
            self.pulse(monitor, api)
        monitor.suppress_for(2)
        self.assertTrue(monitor.snapshot()["suppressed"])
        self.assertEqual(monitor.snapshot()["recent_triggers"], 0)
        for _ in range(5):
            self.pulse(monitor, api)
        self.assertEqual(monitor.snapshot()["total_triggers"], 4)
        self.clock.advance(2)
        self.assertFalse(monitor.snapshot()["suppressed"])
        alert = self.trigger(monitor, api)
        monitor.suppress_for(2)
        self.assertEqual(monitor.snapshot()["active_alert"], alert)

    def test_queued_pre_suppression_and_pre_clear_edges_do_not_rearm(self):
        monitor, api = self.monitor()
        alert = self.trigger(monitor, api)
        with monitor._lock:
            old_time = self.clock()
            for index in range(5):
                monitor._queue.put((1, index * 200_000_000, old_time, self.clock.wall()))
                monitor._queue.put((0, index * 200_000_000 + 2_000_000, old_time, self.clock.wall()))
            monitor.clear_alert(alert["id"])
        monitor._queue.join()
        self.assertIsNone(monitor.snapshot()["active_alert"])
        self.assertEqual(monitor.snapshot()["recent_triggers"], 0)
        with monitor._lock:
            monitor._queue.put((1, 2_000_000_000, old_time, self.clock.wall()))
            monitor.suppress_for(2)
        monitor._queue.join()
        self.assertEqual(monitor.snapshot()["recent_triggers"], 0)

    def test_delayed_hardware_callbacks_from_suppression_do_not_count_after_expiry(self):
        monitor, api = self.monitor()
        self.pulse(monitor, api)
        monitor.suppress_for(2)
        during_suppression = self.clock() + 0.5
        self.clock.advance(3)
        for index in range(5):
            timestamp = 9_000_000_000_000_000_000 + round(
                (during_suppression + index * 0.2) * 1_000_000_000)
            api.emit(1, timestamp)
            api.emit(0, timestamp + 2_000_000)
        monitor._queue.join()
        self.assertFalse(monitor.snapshot()["suppressed"])
        self.assertEqual(monitor.snapshot()["total_triggers"], 1)
        self.assertIsNone(monitor.snapshot()["active_alert"])
        self.assertIsNotNone(self.trigger(monitor, api))

    def test_falling_and_suppressed_edges_establish_timestamp_anchor(self):
        monitor, api = self.monitor()
        api.emit(0)
        monitor._queue.join()
        monitor.suppress_for(2)
        self.pulse(monitor, api)
        self.assertEqual(monitor.snapshot()["total_triggers"], 0)
        source_time = self.clock() + 0.2
        self.clock.advance(3)
        api.emit(1, 9_000_000_000_000_000_000 + round(source_time * 1_000_000_000))
        api.emit(0, 9_000_000_000_000_000_000 + round((source_time + 0.002) * 1_000_000_000))
        monitor._queue.join()
        self.assertEqual(monitor.snapshot()["total_triggers"], 0)

    def test_claim_read_callback_and_import_failures_are_visible_and_release_resources(self):
        for failure in ("open", "claim_alert", "callback", "read"):
            with self.subTest(failure=failure):
                api = FakeGPIO(self.clock)
                api.failure = failure
                monitor, _ = self.monitor(api=api)
                self.assertEqual(monitor.snapshot()["status"], "error")
                self.assertIsNone(monitor.snapshot()["input_level"])
                self.assertTrue(monitor.snapshot()["error"])
                if failure != "open":
                    self.assertTrue(api.closed)
                if failure == "read":
                    self.assertTrue(api.cancelled)
        with patch("vibration.importlib.import_module", side_effect=ImportError("missing")):
            monitor = vibration.VibrationMonitor(self.connect, enabled=True)
            self.monitors.append(monitor)
            monitor.start()
        self.assertEqual(monitor.snapshot()["status"], "error")

    def test_running_read_failure_releases_input_and_reports_error(self):
        monitor, api = self.monitor()
        api.failure = "read"
        self.clock.advance(2)
        self.wait(lambda: monitor.snapshot()["status"] == "error")
        self.wait(lambda: api.closed)
        self.assertTrue(api.cancelled)
        self.assertIsNone(monitor.snapshot()["input_level"])

    def test_queue_overflow_is_reported_instead_of_silently_losing_events(self):
        monitor, api = self.monitor(start=False)
        for index in range(vibration.QUEUE_SIZE + 1):
            monitor._on_edge(0, 21, index % 2, index)
        monitor.start()
        self.wait(lambda: monitor.snapshot()["status"] == "error")
        self.assertIn("overloaded", monitor.snapshot()["error"])
        self.wait(lambda: api.closed)

    def test_persistence_failure_stops_monitor_and_is_visible(self):
        monitor, api = self.monitor()
        for _ in range(4):
            self.pulse(monitor, api)
        with patch.object(monitor, "connect", side_effect=sqlite3.OperationalError("disk full")):
            self.pulse(monitor, api)
            self.wait(lambda: monitor.snapshot()["status"] == "error")
        self.wait(lambda: api.closed)

    def test_claims_only_input21_start_and_close_are_idempotent(self):
        monitor, api = self.monitor()
        monitor.start()
        self.assertEqual([call for call in api.calls if call[0] == "claim_alert"],
                         [("claim_alert", 0, 21, api.BOTH_EDGES, api.SET_PULL_NONE)])
        monitor.close()
        monitor.close()
        monitor.start()
        self.assertEqual([call for call in api.calls if call[0] == "close"], [("close", 0)])
        self.assertEqual([call for call in api.calls if call[0] == "cancel"], [("cancel",)])
        self.assertFalse(monitor._thread.is_alive())
        self.assertEqual(monitor.snapshot()["status"], "disabled")
        self.assertTrue(all(call[0] in {"open", "claim_alert", "callback", "read", "cancel", "close"}
                            for call in api.calls))

    def test_snapshot_is_detached_from_internal_history(self):
        monitor, api = self.monitor()
        alert = self.trigger(monitor, api)
        state = monitor.snapshot()
        state["events"][0]["id"] = "changed"
        state["active_alert"]["id"] = "changed"
        self.assertEqual(monitor.snapshot()["active_alert"]["id"], alert["id"])
        self.assertEqual(monitor.snapshot()["events"][0]["id"], alert["id"])


if __name__ == "__main__":
    unittest.main()
