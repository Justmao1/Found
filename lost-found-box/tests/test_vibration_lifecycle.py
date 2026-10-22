"""Failed server startup releases fake GPIO input and local server resources."""

from pathlib import Path
import socket
import sqlite3
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

import server
from test_vibration import FakeGPIO
import vibration


class VibrationLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.gpio = FakeGPIO()
        self.servers = []
        original_close = server.PhotoServer.server_close

        def capture_close(instance):
            if instance not in self.servers:
                self.servers.append(instance)
            return original_close(instance)

        self.close_patch = patch.object(server.PhotoServer, "server_close", capture_close)
        self.close_patch.start()

    def tearDown(self):
        self.close_patch.stop()
        # Also clean a partially initialized server if a regression makes its
        # normal close path fail, so the failure test itself cannot leak threads.
        for instance in self.servers:
            instance.ai_stopping.set()
            instance.vibration.close()
            worker = getattr(instance, "ai_worker", None)
            if worker is not None and worker.ident is not None:
                worker.join(timeout=2)
            instance.socket.close()
        self.directory.cleanup()

    def build(self, **kwargs):
        return server.build_server(
            "127.0.0.1", kwargs.pop("port", 0), self.directory.name,
            locker_mode="disabled", vibration_enabled=True, vibration_api=self.gpio,
            auto_recognize=kwargs.pop("auto_recognize", False), **kwargs)

    def assert_closed(self, expect_gpio=True):
        self.assertEqual(len(self.servers), 1)
        instance = self.servers[0]
        self.assertEqual(instance.socket.fileno(), -1)
        self.assertTrue(instance.ai_stopping.is_set())
        worker = getattr(instance, "ai_worker", None)
        self.assertFalse(worker is not None and worker.is_alive())
        self.assertEqual(instance.vibration.snapshot()["status"], "disabled")
        if expect_gpio:
            self.assertTrue(self.gpio.closed)
            self.assertTrue(self.gpio.cancelled)
            self.assertFalse(instance.vibration._thread.is_alive())
        else:
            self.assertEqual(self.gpio.calls, [])

    def test_bind_failure_keeps_original_error_without_starting_hardware(self):
        with socket.socket() as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen()
            with self.assertRaises(OSError):
                self.build(port=occupied.getsockname()[1])
        self.assert_closed(expect_gpio=False)

    def test_recognition_startup_database_failure_releases_running_monitor(self):
        original_connect = server.PhotoServer.connect_db

        def connect(instance):
            monitor = getattr(instance, "vibration", None)
            if monitor is not None and monitor._started:
                if instance not in self.servers:
                    self.servers.append(instance)
                raise sqlite3.OperationalError("startup scan fixture")
            return original_connect(instance)

        with patch.object(server.PhotoServer, "connect_db", connect), \
                patch.object(server.vision, "configuration_status", return_value={"configured": True}):
            with self.assertRaisesRegex(sqlite3.OperationalError, "startup scan fixture"):
                self.build(auto_recognize=True)
        self.assert_closed()

    def test_ai_thread_start_failure_does_not_join_an_unstarted_thread(self):
        with patch.object(threading.Thread, "start", side_effect=RuntimeError("thread fixture")):
            with self.assertRaisesRegex(RuntimeError, "thread fixture"):
                self.build()
        self.assert_closed(expect_gpio=False)

    def test_tls_wrap_failure_releases_monitor_and_server(self):
        context = Mock()
        context.wrap_socket.side_effect = OSError("TLS wrap fixture")
        with patch.object(server.ssl, "SSLContext", return_value=context):
            with self.assertRaisesRegex(OSError, "TLS wrap fixture"):
                self.build(cert="fixture.crt", key="fixture.key")
        self.assert_closed()

    def test_monitor_thread_start_failure_can_still_close(self):
        path = Path(self.directory.name) / "monitor.sqlite3"
        monitor = vibration.VibrationMonitor(lambda: sqlite3.connect(path), enabled=True, api=self.gpio)
        with patch.object(threading.Thread, "start", side_effect=RuntimeError("thread fixture")):
            monitor.start()
        self.assertEqual(monitor.snapshot()["status"], "error")
        self.assertTrue(self.gpio.closed)
        self.assertTrue(self.gpio.cancelled)
        monitor.close()
        self.assertEqual(monitor.snapshot()["status"], "disabled")


if __name__ == "__main__":
    unittest.main()
