from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch
import uuid

import lockers
import door_feedback
import vision
import search
import test_server as server_tests


class ManualLockerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / "items.sqlite3"
        db = self.connect()
        db.executescript("""
            CREATE TABLE items(id TEXT PRIMARY KEY);
            CREATE TABLE recognitions(item_id TEXT PRIMARY KEY REFERENCES items(id),result TEXT);
        """)
        db.close()
        self.driver = Mock()
        self.driver.name = "simulated"
        self.driver.cooldown_seconds = 0
        self.store = lockers.LockerStore(self.connect, self.directory.name, self.driver)

    def tearDown(self):
        self.directory.cleanup()

    def connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        return db

    def add_item(self):
        identifier = str(uuid.uuid4())
        db = self.connect()
        with db:
            db.execute("INSERT INTO items VALUES(?)", (identifier,))
            db.execute("INSERT INTO recognitions VALUES(?,?)", (identifier, json.dumps(
                {"tags": ["keys"], "model": "test", "version": 3})))
        db.close()
        return identifier

    def visitor_start(self, item=None, kind="deposit"):
        return self.store.start(str(uuid.uuid4()), item or self.add_item(), kind)[0]

    def manual_open(self, compartment="01", reason="检查锁舌", request_id=None):
        return self.store.manual_open(request_id or str(uuid.uuid4()), compartment, reason)

    def slot(self, compartment="01"):
        return next(slot for slot in self.store.snapshot()["compartments"] if slot["id"] == compartment)

    def assert_error(self, code, function, *args):
        with self.assertRaises(vision.VisionError) as error:
            function(*args)
        self.assertEqual(error.exception.status, code)

    def test_empty_slot_completes_without_confirmation_and_replays_idempotently(self):
        operation, duplicate = self.manual_open(reason="  检查锁舌  ")
        self.assertFalse(duplicate)
        self.assertEqual(operation["reason"], "检查锁舌")
        self.assertEqual(operation["state"], "completed")
        self.assertIsNone(operation["item_id"])
        self.assertIsInstance(operation["created_at"], float)
        self.assertEqual(self.slot()["state"], "free")
        self.assertEqual(self.store.manual_list(), [])
        self.assertEqual(self.store.manual_get(operation["id"]), operation)
        finished = self.store.manual_confirm(operation["id"])
        self.assertEqual(finished["state"], "completed")
        self.assertEqual(self.slot()["state"], "free")
        self.assertEqual(self.store.manual_confirm(operation["id"]), finished)
        self.assertEqual(self.store.manual_list(), [])
        self.driver.pulse.assert_called_once_with("01")

    def test_occupied_slot_keeps_item_and_allows_later_visitor_retrieval(self):
        visitor = self.visitor_start()
        self.store.finish(visitor["id"])
        operation, _ = self.manual_open()
        self.assertEqual(operation["state"], "completed")
        self.assertEqual(operation["item_id"], visitor["item_id"])
        self.assert_error(409, self.visitor_start, visitor["item_id"], "deposit")
        self.assertEqual(self.slot(), {"id": "01", "state": "occupied", "item_id": visitor["item_id"],
                                      "door": door_feedback.not_configured()})
        db = self.connect()
        self.assertEqual(db.execute("SELECT status FROM item_storage WHERE item_id=?", (visitor["item_id"],)).fetchone()[0], "stored")
        db.close()
        self.assertEqual(self.visitor_start(visitor["item_id"], "retrieve")["state"], "awaiting_confirmation")

    def test_pending_visitor_operation_survives_manual_reopen_and_can_finish_normally(self):
        visitor = self.visitor_start()
        operation, _ = self.manual_open()
        self.assertEqual(self.store.get(visitor["id"])["state"], "awaiting_confirmation")
        self.assertEqual(operation["state"], "completed")
        self.assertEqual(self.slot()["state"], "reserved")
        self.assertEqual(self.store.get(visitor["id"])["state"], "awaiting_confirmation")
        self.assertEqual(self.store.finish(visitor["id"])["state"], "completed")
        self.assertEqual(self.slot()["state"], "occupied")

    def test_retrieving_and_recovery_state_are_restored_without_claiming_collection(self):
        visitor = self.visitor_start()
        self.store.finish(visitor["id"])
        retrieval = self.visitor_start(visitor["item_id"], "retrieve")
        operation, _ = self.manual_open()
        self.assertEqual(operation["state"], "completed")
        self.assertEqual(self.slot()["state"], "retrieving")
        self.assertEqual(self.store.get(retrieval["id"])["state"], "awaiting_confirmation")
        self.store.finish(retrieval["id"])
        self.driver.pulse.side_effect = RuntimeError("private failure")
        failed = self.visitor_start()
        self.driver.pulse.side_effect = None
        operation, _ = self.manual_open()
        self.assertEqual(operation["state"], "completed")
        self.assertEqual(self.slot()["state"], "recovery")
        self.assertEqual(self.store.get(failed["id"])["state"], "uncertain")

    def test_concurrent_replays_and_conflicting_ids_never_duplicate_pulse(self):
        identifier = str(uuid.uuid4())
        with ThreadPoolExecutor(max_workers=5) as pool:
            results = list(pool.map(lambda _: self.manual_open(request_id=identifier), range(5)))
        self.assertEqual(sorted(duplicate for _, duplicate in results), [False, True, True, True, True])
        self.assertTrue(all(operation["state"] == "completed" for operation, _ in results))
        self.assert_error(409, self.manual_open, "02", "检查锁舌", identifier)
        self.assert_error(409, self.manual_open, "01", "另一原因", identifier)
        self.driver.pulse.assert_called_once_with("01")

    def test_omitted_and_empty_reasons_share_the_default_and_same_replay(self):
        identifier = str(uuid.uuid4())
        operation, duplicate = self.store.manual_open(identifier, "01")
        self.assertFalse(duplicate)
        self.assertEqual(operation["reason"], "Manual opening")
        self.assertEqual(operation["state"], "completed")
        for reason in ("", "  ", "Manual opening"):
            replay, duplicate = self.store.manual_open(identifier, "01", reason)
            self.assertTrue(duplicate)
            self.assertEqual(replay, operation)
        self.driver.pulse.assert_called_once_with("01")

    def test_active_manual_pulse_blocks_confirmation_and_visitor_completion(self):
        visitor = self.visitor_start()
        identifier = str(uuid.uuid4())
        other = lockers.LockerStore(self.connect, self.directory.name, self.driver)
        def during_pulse(_compartment):
            self.assertEqual(other.manual_get(identifier)["state"], "actuating")
            self.assert_error(409, other.manual_confirm, identifier)
            self.assert_error(409, self.store.finish, visitor["id"])
        self.driver.pulse.side_effect = during_pulse
        operation, _ = self.manual_open(request_id=identifier)
        self.assertEqual(operation["state"], "completed")
        self.assertEqual(self.slot()["state"], "reserved")

    def test_confirmation_waits_while_a_different_compartment_is_actively_pulsing(self):
        self.driver.pulse.side_effect = RuntimeError("fixture failure")
        first, _ = self.manual_open()
        self.driver.pulse.side_effect = None
        other = lockers.LockerStore(self.connect, self.directory.name, self.driver)
        def during_pulse(_compartment):
            self.assert_error(409, other.manual_confirm, first["id"])
        self.driver.pulse.side_effect = during_pulse
        second, _ = self.manual_open("02")
        self.assertEqual(second["state"], "completed")
        self.assertEqual(self.slot()["state"], "maintenance")
        self.assertEqual(self.store.manual_confirm(first["id"])["state"], "completed")

    def test_visitor_waits_for_manual_pulse_then_can_use_restored_free_slot(self):
        entered, release = threading.Event(), threading.Event()
        def during_pulse(compartment):
            if compartment == "01":
                entered.set()
                self.assertTrue(release.wait(3))
        self.driver.pulse.side_effect = during_pulse
        with ThreadPoolExecutor(max_workers=2) as pool:
            manual = pool.submit(self.manual_open)
            self.assertTrue(entered.wait(2))
            visitor = pool.submit(self.visitor_start)
            self.assertFalse(visitor.done())
            self.assertEqual(self.slot()["state"], "maintenance")
            release.set()
            self.assertEqual(manual.result(3)[0]["state"], "completed")
            self.assertEqual(visitor.result(3)["compartment_id"], "01")

    def test_manual_waits_for_visitor_pulse_before_reopening_and_preserves_its_operation(self):
        entered, release = threading.Event(), threading.Event()
        calls = []
        def during_pulse(compartment):
            calls.append(compartment)
            if len(calls) == 1:
                entered.set()
                self.assertTrue(release.wait(3))
        self.driver.pulse.side_effect = during_pulse
        with ThreadPoolExecutor(max_workers=2) as pool:
            visitor_future = pool.submit(self.visitor_start)
            self.assertTrue(entered.wait(2))
            manual_future = pool.submit(self.manual_open)
            release.set()
            visitor = visitor_future.result(3)
            manual = manual_future.result(3)[0]
        self.assertEqual(manual["state"], "completed")
        self.assertEqual(self.store.get(visitor["id"])["state"], "awaiting_confirmation")
        self.assertEqual(self.store.finish(visitor["id"])["state"], "completed")
        self.assertEqual(calls, ["01", "01"])

    def test_startup_recovers_actuation_and_never_repeats_pulse(self):
        class ProcessStopped(BaseException):
            pass
        identifier = str(uuid.uuid4())
        self.driver.pulse.side_effect = ProcessStopped()
        with self.assertRaises(ProcessStopped):
            self.manual_open(request_id=identifier)
        restarted = lockers.LockerStore(self.connect, self.directory.name, self.driver)
        operation, duplicate = restarted.manual_open(identifier, "01", "检查锁舌")
        self.assertTrue(duplicate)
        self.assertEqual(operation["state"], "uncertain")
        self.assertEqual(restarted.snapshot()["compartments"][0]["state"], "maintenance")
        self.assertEqual(restarted.manual_confirm(identifier)["state"], "completed")
        self.driver.pulse.assert_called_once_with("01")

    def test_post_pulse_write_failure_and_later_recovery_stay_in_maintenance(self):
        db = self.connect()
        db.execute("CREATE TRIGGER reject_manual_update BEFORE UPDATE OF state ON manual_openings "
                   "WHEN NEW.state IN ('completed','uncertain') "
                   "BEGIN SELECT RAISE(FAIL,'injected failure'); END")
        db.close()
        identifier = str(uuid.uuid4())
        with self.assertRaises(sqlite3.Error):
            self.manual_open(request_id=identifier)
        db = self.connect()
        self.assertEqual(db.execute("SELECT state FROM compartments WHERE id='01'").fetchone()[0], "maintenance")
        db.execute("DROP TRIGGER reject_manual_update")
        db.close()
        self.assertEqual(self.store.manual_get(identifier)["state"], "uncertain")
        self.assertTrue(self.manual_open(request_id=identifier)[1])
        self.assertEqual(self.store.manual_confirm(identifier)["state"], "completed")
        self.driver.pulse.assert_called_once_with("01")

    def test_pulse_failure_is_safe_and_can_be_physically_acknowledged(self):
        self.driver.pulse.side_effect = RuntimeError("private failure")
        operation, _ = self.manual_open()
        self.assertEqual(operation["state"], "uncertain")
        self.assertNotIn("private", json.dumps(operation))
        self.assertEqual(self.slot()["state"], "maintenance")
        self.assert_error(409, self.manual_open)
        self.assertTrue(self.manual_open(request_id=operation["id"])[1])
        self.store.manual_confirm(operation["id"])
        self.assertEqual(self.slot()["state"], "free")
        self.driver.pulse.assert_called_once_with("01")

    def test_post_pulse_write_failure_marks_uncertain_immediately_when_database_allows(self):
        db = self.connect()
        db.execute("CREATE TRIGGER reject_manual_confirmation BEFORE UPDATE OF state ON manual_openings "
                   "WHEN NEW.state='completed' BEGIN SELECT RAISE(FAIL,'injected failure'); END")
        db.close()
        operation, _ = self.manual_open()
        self.assertEqual(operation["state"], "uncertain")
        self.assertEqual(self.slot()["state"], "maintenance")
        self.driver.pulse.assert_called_once_with("01")

    def test_legacy_pending_confirmation_restores_saved_state_without_replaying(self):
        visitor = self.visitor_start()
        self.driver.pulse.side_effect = RuntimeError("fixture failure")
        operation, _ = self.manual_open()
        db = self.connect()
        with db:
            db.execute("UPDATE manual_openings SET state='awaiting_confirmation',error=NULL WHERE id=?",
                       (operation["id"],))
        db.close()
        restarted = lockers.LockerStore(self.connect, self.directory.name, self.driver)
        self.assertEqual(restarted.manual_get(operation["id"])["state"], "awaiting_confirmation")
        self.assertTrue(restarted.manual_open(operation["id"], "01", operation["reason"])[1])
        self.assertEqual(restarted.manual_confirm(operation["id"])["state"], "completed")
        self.assertEqual(self.slot()["state"], "reserved")
        self.assertEqual(restarted.get(visitor["id"])["state"], "awaiting_confirmation")
        self.assertEqual(self.driver.pulse.call_count, 2)

    def test_changed_inventory_during_pulse_keeps_manual_command_unresolved(self):
        visitor = self.visitor_start()
        self.store.finish(visitor["id"])
        def change_inventory(_compartment):
            db = self.connect()
            with db:
                db.execute("UPDATE item_storage SET status='collected' WHERE item_id=?", (visitor["item_id"],))
            db.close()
        self.driver.pulse.side_effect = change_inventory
        operation, _ = self.manual_open()
        self.assertEqual(operation["state"], "uncertain")
        self.assertEqual(self.slot()["state"], "maintenance")
        self.assert_error(409, self.store.manual_confirm, operation["id"])
        self.assertEqual(self.driver.pulse.call_count, 2)

    def test_manual_and_visitor_openings_share_persistent_cooldown(self):
        self.driver.cooldown_seconds = 30
        operation, _ = self.manual_open()
        self.assertEqual(operation["state"], "completed")
        self.assert_error(429, self.manual_open)
        visitor = self.visitor_start()
        self.assertEqual(visitor["compartment_id"], "02")
        self.assert_error(429, self.manual_open, "02")
        self.assertEqual(self.driver.pulse.call_count, 2)

    def test_search_excludes_active_pulse_and_restores_inventory_without_confirmation(self):
        with tempfile.TemporaryDirectory() as directory:
            server = server_tests.server_module.build_server("127.0.0.1", 0, directory,
                                                             auto_recognize=False, locker_driver=self.driver)
            try:
                item = str(uuid.uuid4())
                db = server.connect_db()
                with db:
                    db.execute("INSERT INTO items VALUES(?,?,?,'2026-10-22T00:00:00Z','','image/png',?)",
                               (item, str(uuid.uuid4()), "test", server_tests.png()))
                    db.execute("INSERT INTO recognitions VALUES(?,?)", (item, json.dumps(
                        {"tags": ["keys"], "model": "test", "version": 3})))
                db.close()
                visitor, _ = server.lockers.start(str(uuid.uuid4()), item, "deposit")
                server.lockers.finish(visitor["id"])
                with patch.object(search, "find_matches", return_value=[{"id": 1, "reason": "Keys."}]):
                    self.assertEqual(server.search_items("keys")["searched_count"], 1)
                    self.driver.pulse.side_effect = lambda _slot: self.assertEqual(
                        server.search_items("keys")["matches"], [])
                    manual, _ = server.lockers.manual_open(str(uuid.uuid4()), "01", "check")
                    self.assertEqual(manual["state"], "completed")
                    result = server.search_items("keys")
                    self.assertEqual(result["matches"][0]["item"]["id"], item)
                    self.assertEqual(result["matches"][0]["item"]["status"], "stored")
            finally:
                server.server_close()

    def test_preflight_cooldown_and_disabled_mode_do_not_allocate(self):
        self.driver.preflight.side_effect = RuntimeError("private")
        self.assert_error(503, self.manual_open)
        self.assertEqual(self.slot()["state"], "free")
        self.driver.preflight.side_effect = None
        self.driver.cooldown_seconds = 30
        db = self.connect()
        with db:
            db.execute("INSERT INTO locker_pulses VALUES('01',?)", (time.time(),))
        db.close()
        self.assert_error(429, self.manual_open)
        disabled = lockers.LockerStore(self.connect, self.directory.name, None)
        self.assert_error(503, disabled.manual_open, str(uuid.uuid4()), "02", "check")
        self.assertEqual(self.store.manual_list(), [])
        self.driver.pulse.assert_not_called()

    def test_validation_rejects_invalid_reason_ids_and_unknown_operations(self):
        for reason in (None, 4, [], "x" * 201, "\ud800"):
            self.assert_error(400, self.manual_open, "01", reason)
        for compartment in (None, 1, [], "1", "05"):
            self.assert_error(400, self.manual_open, compartment)
        self.assert_error(400, self.manual_open, "01", "check", "bad")
        self.assert_error(400, self.store.manual_get, "bad")
        self.assert_error(404, self.store.manual_get, str(uuid.uuid4()))
        self.assert_error(404, self.store.manual_confirm, str(uuid.uuid4()))
        self.driver.pulse.assert_not_called()

    def test_old_confirmation_cannot_release_a_new_maintenance_operation(self):
        first, _ = self.manual_open()
        self.driver.pulse.side_effect = RuntimeError("fixture failure")
        second, _ = self.manual_open()
        self.store.manual_confirm(first["id"])
        self.assertEqual(self.slot()["state"], "maintenance")
        self.assertEqual(self.store.manual_list(), [second])

    def test_changed_slot_or_item_state_refuses_restore(self):
        visitor = self.visitor_start()
        self.store.finish(visitor["id"])
        self.driver.pulse.side_effect = RuntimeError("fixture failure")
        operation, _ = self.manual_open()
        db = self.connect()
        with db:
            db.execute("UPDATE item_storage SET status='collected' WHERE item_id=?", (visitor["item_id"],))
        db.close()
        self.assert_error(409, self.store.manual_confirm, operation["id"])
        self.assertEqual(self.slot()["state"], "maintenance")


if __name__ == "__main__":
    unittest.main()
