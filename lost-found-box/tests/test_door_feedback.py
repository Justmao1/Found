"""Door input tests use fake GPIO reads only; no relay output is claimed."""

import os
import socket
import sqlite3
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

import door_feedback
import server
from test_vibration import FakeClock


class FakeGPIO:
    SET_PULL_UP = 32

    def __init__(self, level=0):
        self.level = level
        self.levels = {}
        self.failed_pins = set()
        self.claim_failures = set()
        self.calls = []
        self.failure = None
        self.closed = False

    def _call(self, name, *args):
        self.calls.append((name, *args))
        if self.failure == name:
            raise RuntimeError("private GPIO fixture")

    def gpiochip_open(self, chip):
        self._call("open", chip)
        return 0

    def gpio_claim_input(self, handle, gpio, lFlags=0):
        self._call("claim_input", handle, gpio, lFlags)
        if gpio in self.claim_failures:
            raise RuntimeError("private claim fixture")
        return 0

    def gpio_read(self, handle, gpio):
        self._call("read", handle, gpio)
        if gpio in self.failed_pins:
            raise RuntimeError("private input fixture")
        return self.levels.get(gpio, self.level)

    def gpiochip_close(self, handle):
        self._call("close", handle)
        self.closed = True


class DoorFeedbackTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.gpio = FakeGPIO()
        self.monitor = door_feedback.DoorFeedbackMonitor(
            enabled=True, api=self.gpio, clock=self.clock, wall_clock=self.clock.wall)
        self.addCleanup(self.monitor.close)

    def start(self):
        # Deterministic sample timing; the hardware boundary is still exercised.
        with patch.object(threading.Thread, "start"):
            self.monitor.start()

    def sample(self, level, seconds=0):
        self.clock.advance(seconds)
        self.gpio.level = level
        self.monitor._sample()
        return self.monitor.snapshot("01")

    def test_disabled_and_unwired_slots_never_claim_or_imply_closed(self):
        monitor = door_feedback.DoorFeedbackMonitor()
        with patch.object(door_feedback.importlib, "import_module") as importing:
            monitor.start()
            self.assertEqual(monitor.snapshot("01"), door_feedback.not_configured())
            monitor.close()
            importing.assert_not_called()
        self.start()
        for compartment in ("03", "04"):
            self.assertEqual(self.monitor.snapshot(compartment), door_feedback.not_configured())
        self.assertEqual(self.gpio.calls, [("open", 0), ("claim_input", 0, 12, 32),
                                         ("claim_input", 0, 18, 32), ("read", 0, 12), ("read", 0, 18)])

    def test_second_contact_debounces_independently_of_first(self):
        self.gpio.levels = {12: 0, 18: 1}
        self.start()
        self.sample(0, .25)
        self.assertEqual(self.monitor.snapshot("01")["state"], "closed")
        second = self.monitor.snapshot("02")
        self.assertEqual((second["state"], second["gpio"], second["pin"]), ("open", 18, 12))
        self.gpio.levels[18] = 0
        self.sample(0, .01)
        self.assertEqual(self.monitor.snapshot("02")["state"], "unknown")
        self.assertEqual(self.monitor.snapshot("01")["state"], "closed")
        self.sample(0, .25)
        self.assertEqual(self.monitor.snapshot("02")["state"], "closed")
        self.gpio.levels[12] = 1
        self.sample(0)
        self.assertEqual(self.monitor.snapshot("01")["state"], "unknown")
        self.assertEqual(self.monitor.snapshot("02")["state"], "closed")

    def test_one_input_failure_does_not_disable_other_contact(self):
        for stage in ("claim", "read"):
            with self.subTest(stage=stage):
                gpio = FakeGPIO()
                if stage == "claim": gpio.claim_failures.add(18)
                else: gpio.failed_pins.add(18)
                monitor = door_feedback.DoorFeedbackMonitor(enabled=True, api=gpio,
                    clock=self.clock, wall_clock=self.clock.wall)
                try:
                    with patch.object(threading.Thread, "start"): monitor.start()
                    self.clock.advance(.25)
                    monitor._sample()
                    self.assertEqual(monitor.snapshot("01")["state"], "closed")
                    self.assertEqual(monitor.snapshot("02")["state"], "unavailable")
                    self.assertIn("GPIO18", monitor.snapshot("02")["error"])
                    self.assertFalse(gpio.closed)
                finally:
                    monitor.close()
                self.assertTrue(gpio.closed)

    def test_debounce_waits_for_stable_level_and_never_keeps_closed_during_transition(self):
        self.start()
        self.assertEqual(self.monitor.snapshot("01")["state"], "unknown")
        self.assertEqual(self.sample(0, .24)["state"], "unknown")
        self.assertEqual(self.sample(0, .01)["state"], "closed")
        opened = self.sample(1, .01)
        self.assertEqual((opened["state"], opened["level"]), ("unknown", 1))
        self.assertEqual(self.sample(0, .1)["state"], "unknown")
        self.assertEqual(self.sample(1, .1)["state"], "unknown")
        self.assertEqual(self.sample(1, .25)["state"], "open")
        self.assertEqual(self.sample(0, .01)["state"], "unknown")
        closed = self.sample(0, .25)
        self.assertEqual((closed["state"], closed["gpio"], closed["pin"]), ("closed", 12, 32))
        self.assertEqual(closed["updated_at"], self.clock.wall())

    def test_stale_data_cannot_confirm_closed_and_recovery_requires_new_stability(self):
        self.start()
        self.sample(0, .25)
        self.clock.advance(1)
        stale = self.monitor.snapshot("01")
        self.assertEqual(stale["state"], "unavailable")
        self.assertIsNone(stale["level"])
        self.assertTrue(stale["error"])
        self.assertEqual(self.sample(0)["state"], "unknown")
        self.assertEqual(self.sample(0, .25)["state"], "closed")

    def test_startup_failures_release_claim_and_hide_internal_details(self):
        for stage in ("open", "claim_input", "read"):
            with self.subTest(stage=stage):
                gpio = FakeGPIO()
                gpio.failure = stage
                monitor = door_feedback.DoorFeedbackMonitor(enabled=True, api=gpio)
                monitor.start()
                snapshot = monitor.snapshot("01")
                self.assertEqual(snapshot["state"], "unavailable")
                self.assertNotIn("private", snapshot["error"])
                self.assertEqual(gpio.closed, stage != "open")
                monitor.close()

    def test_thread_start_failure_releases_input(self):
        with patch.object(threading.Thread, "start", side_effect=RuntimeError("fixture")):
            self.monitor.start()
        self.assertTrue(self.gpio.closed)
        self.assertEqual(self.monitor.snapshot("01")["state"], "unavailable")
        self.monitor.close()

    def test_background_read_failure_is_visible_and_releases_input(self):
        monitor = door_feedback.DoorFeedbackMonitor(enabled=True, api=self.gpio)
        self.addCleanup(monitor.close)
        monitor.start()
        self.gpio.failure = "read"
        deadline = time.monotonic() + 2
        while not self.gpio.closed and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertTrue(self.gpio.closed)
        self.assertEqual(monitor.snapshot("01")["state"], "unavailable")
        monitor.close()
        self.assertFalse(monitor._thread.is_alive())

    def test_invalid_gpio_read_does_not_report_a_door_state(self):
        self.gpio.level = -1
        self.monitor.start()
        self.assertEqual(self.monitor.snapshot("01")["state"], "unavailable")
        self.assertTrue(self.gpio.closed)

    def test_close_releases_once_and_cannot_restart_with_old_closed_state(self):
        self.start()
        self.sample(0, .25)
        self.monitor.close()
        self.monitor.close()
        self.monitor.start()
        self.assertEqual(self.monitor.snapshot("01")["state"], "unavailable")
        self.assertEqual(self.gpio.calls.count(("close", 0)), 1)
        self.assertEqual(self.gpio.calls.count(("open", 0)), 1)


class DoorServerLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.gpio = FakeGPIO()
        self.monitor = door_feedback.DoorFeedbackMonitor(enabled=True, api=self.gpio)
        self.addCleanup(self.monitor.close)

    def build(self, **kwargs):
        return server.build_server("127.0.0.1", kwargs.pop("port", 0), self.directory.name,
                                   locker_mode="disabled", vibration_enabled=False,
                                   auto_recognize=kwargs.pop("auto_recognize", False),
                                   door_monitor=self.monitor, **kwargs)

    def test_bind_failure_does_not_claim_door_input(self):
        with socket.socket() as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen()
            with self.assertRaises(OSError):
                self.build(port=occupied.getsockname()[1])
        self.assertEqual(self.gpio.calls, [])

    def test_startup_database_failure_releases_door_thread(self):
        connect = server.PhotoServer.connect_db

        def failing(instance):
            if self.monitor._started:
                raise sqlite3.OperationalError("startup fixture")
            return connect(instance)

        with patch.object(server.PhotoServer, "connect_db", failing), \
                patch.object(server.vision, "configuration_status", return_value={"configured": True}):
            with self.assertRaisesRegex(sqlite3.OperationalError, "startup fixture"):
                self.build(auto_recognize=True)
        self.assertTrue(self.gpio.closed)
        self.assertFalse(self.monitor._thread.is_alive())

    def test_tls_wrap_failure_releases_door_input(self):
        context = Mock()
        context.wrap_socket.side_effect = OSError("TLS fixture")
        with patch.object(server.ssl, "SSLContext", return_value=context):
            with self.assertRaisesRegex(OSError, "TLS fixture"):
                self.build(cert="fixture.crt", key="fixture.key")
        self.assertTrue(self.gpio.closed)
        self.assertFalse(self.monitor._thread.is_alive())

    def test_environment_requires_explicit_enable_and_build_injects_fake_api(self):
        with patch.dict(os.environ, {"LOST_FOUND_DOOR_FEEDBACK_ENABLED": "invalid"}):
            with self.assertRaisesRegex(ValueError, "LOST_FOUND_DOOR_FEEDBACK_ENABLED"):
                self.build()
        with patch.dict(os.environ, {"LOST_FOUND_DOOR_FEEDBACK_ENABLED": "1"}):
            instance = server.build_server("127.0.0.1", 0, self.directory.name,
                locker_mode="disabled", vibration_enabled=False, auto_recognize=False,
                door_feedback_api=self.gpio)
        try:
            self.assertTrue(instance.door_feedback.enabled)
            self.assertIs(instance.lockers.door_monitor, instance.door_feedback)
            self.assertEqual(instance.lockers.door_snapshot("01")["gpio"], 12)
            self.assertEqual(instance.lockers.door_snapshot("02")["gpio"], 18)
        finally:
            instance.server_close()
        self.assertTrue(self.gpio.closed)


if __name__ == "__main__":
    unittest.main()
