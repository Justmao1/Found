from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch
import uuid

import lockers
import search
import vision
import test_server as server_tests


class FakeDriver:
    name = "simulated"
    cooldown_seconds = 0

    def __init__(self):
        self.pulses = []
        self.failure = None
        self.unavailable = False
        self.before_pulse = None

    def preflight(self):
        if self.unavailable:
            raise RuntimeError("private device details")

    def pulse(self, compartment):
        self.pulses.append(compartment)
        if self.before_pulse:
            self.before_pulse()
        if self.failure:
            raise self.failure


class LockerHTTPTests(unittest.TestCase):
    request = server_tests.PhotoServerTests.request
    stop_server = server_tests.PhotoServerTests.stop_server

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"LOST_FOUND_AI_CONFIG": str(Path(self.directory.name) / "absent.json"),
                                          "DASHSCOPE_API_KEY": "", "LOST_FOUND_LOCKER_MODE": "disabled"})
        self.env.start()
        self.driver = FakeDriver()
        self.start_server()

    def start_server(self):
        self.server = server_tests.server_module.build_server(
            "127.0.0.1", 0, self.directory.name, auto_recognize=False, locker_driver=self.driver)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.stop_server()
        self.env.stop()
        self.directory.cleanup()

    def add_item(self, recognized=True):
        identifier = str(uuid.uuid4())
        db = self.server.connect_db()
        try:
            with db:
                db.execute("INSERT INTO items VALUES(?,?,?,'2026-10-22T00:00:00Z','','image/png',?)",
                           (identifier, str(uuid.uuid4()), "test", server_tests.png()))
                if recognized:
                    db.execute("INSERT INTO recognitions VALUES(?,?)", (identifier, json.dumps(
                        {"tags": ["keys", "silver"], "model": "test", "version": 3})))
        finally:
            db.close()
        return identifier

    def post(self, path, payload=None, headers=None):
        request_headers = {"Content-Type": "application/json", "X-Requested-With": "lost-found-box"}
        request_headers.update(headers or {})
        status, _, raw = self.request("POST", path, json.dumps({} if payload is None else payload).encode(), request_headers)
        return status, json.loads(raw)

    def get(self, path):
        status, _, raw = self.request("GET", path)
        return status, json.loads(raw)

    def start(self, item, kind="deposit", request_id=None):
        return self.post("/api/locker-operations", {"item_id": item, "kind": kind,
                         "request_id": request_id or str(uuid.uuid4())})

    def complete(self, operation):
        return self.post(f"/api/locker-operations/{operation['id']}/complete")

    def test_deposit_retrieve_completion_and_slot_reuse(self):
        item = self.add_item()
        status, body = self.start(item)
        self.assertEqual(status, 201)
        operation = body["operation"]
        self.assertEqual(operation["compartment_id"], "01")
        self.assertEqual(operation["state"], "awaiting_confirmation")
        self.assertEqual(body["item"]["status"], "deposit_pending")
        self.assertEqual(self.get("/api/items?available=1")[1]["total"], 0)
        status, stored = self.complete(operation)
        self.assertEqual(status, 200)
        self.assertEqual(stored["item"]["status"], "stored")
        self.assertEqual(self.complete(operation)[1], stored)
        self.assertEqual(self.get("/api/items?available=1")[1]["total"], 1)
        status, body = self.start(item, "retrieve")
        self.assertEqual(status, 201)
        self.assertEqual(body["item"]["status"], "retrieval_pending")
        self.assertEqual(self.get("/api/items?available=1")[1]["total"], 0)
        status, body = self.complete(body["operation"])
        self.assertEqual(body["item"]["status"], "collected")
        self.assertIsNone(body["item"]["compartment_id"])
        self.assertEqual(self.get("/api/lockers")[1]["compartments"][0]["state"], "free")
        self.assertEqual(self.start(item, "retrieve")[0], 409)
        self.assertEqual(self.start(item)[0], 409)
        self.assertEqual(self.start(self.add_item())[1]["operation"]["compartment_id"], "01")
        self.assertEqual(self.driver.pulses, ["01", "01", "01"])

    def test_concurrent_four_allocations_and_fifth_rejected(self):
        items = [self.add_item() for _ in range(5)]
        with ThreadPoolExecutor(max_workers=5) as pool:
            results = list(pool.map(self.start, items))
        self.assertEqual(sorted(status for status, _ in results), [201] * 4 + [409])
        slots = [body["operation"]["compartment_id"] for status, body in results if status == 201]
        self.assertEqual(sorted(slots), ["01", "02", "03", "04"])
        self.assertEqual(len(self.driver.pulses), 4)

    def test_concurrent_replay_and_distinct_ids_cannot_repeat_pulse(self):
        item, request_id = self.add_item(), str(uuid.uuid4())
        with ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda _: self.start(item, request_id=request_id), range(6)))
        self.assertEqual(sorted(status for status, _ in results), [200] * 5 + [201])
        self.assertEqual(len(self.driver.pulses), 1)
        self.assertEqual(self.start(item)[0], 409)
        self.assertEqual(self.start(self.add_item(), request_id=request_id)[0], 409)
        self.assertEqual(self.start(item, "retrieve", request_id)[0], 409)
        self.assertEqual(len(self.driver.pulses), 1)

    def test_intent_commits_before_pulse_and_reads_never_pulse(self):
        request_id = str(uuid.uuid4())
        other = lockers.LockerStore(self.server.connect_db, self.directory.name, self.driver)
        def inspect():
            status, body = self.get(f"/api/locker-operations/{request_id}")
            self.assertEqual(status, 200)
            self.assertEqual(body["operation"]["state"], "actuating")
            self.assertEqual(self.post(f"/api/locker-operations/{request_id}/complete")[0], 409)
            self.assertEqual(self.post(f"/api/locker-operations/{request_id}/resolve", {"outcome": "stored"})[0], 409)
            # A second manager has a different thread lock, so this exercises the
            # shared file lock protecting active pulses from idle recovery.
            self.assertEqual(other.get(request_id)["state"], "actuating")
            with self.assertRaises(vision.VisionError) as error:
                other.finish(request_id)
            self.assertEqual(error.exception.status, 409)
        self.driver.before_pulse = inspect
        status, body = self.start(self.add_item(), request_id=request_id)
        self.assertEqual(status, 201)
        self.assertEqual(body["operation"]["state"], "awaiting_confirmation")
        self.get("/api/lockers")
        self.get(f"/api/locker-operations/{request_id}")
        self.assertEqual(len(self.driver.pulses), 1)

    def test_search_only_stored_and_stale_candidate_retrieval_rejected(self):
        self.add_item()  # Legacy photo-only record is not public inventory.
        item = self.add_item()
        _, body = self.start(item)
        with patch.object(search, "find_matches", return_value=[]) as provider:
            self.assertEqual(self.post("/api/search", {"query": "keys"})[1]["searched_count"], 0)
            provider.assert_not_called()
            self.complete(body["operation"])
            self.assertEqual(self.post("/api/search", {"query": "keys"})[1]["searched_count"], 1)
            self.assertEqual(len(provider.call_args.args[1]), 1)
            self.start(item, "retrieve")
            self.assertEqual(self.post("/api/search", {"query": "keys"})[1]["searched_count"], 0)
            self.assertEqual(self.start(item, "retrieve")[0], 409)

    def test_preflight_failure_does_not_allocate_or_actuate(self):
        self.driver.unavailable = True
        status, body = self.start(self.add_item())
        self.assertEqual(status, 503)
        self.assertNotIn("private", json.dumps(body))
        snapshot = self.get("/api/lockers")[1]
        self.assertTrue(all(slot["state"] == "free" for slot in snapshot["compartments"]))
        self.assertEqual(snapshot["operations"], [])
        self.assertEqual(self.driver.pulses, [])

    def test_search_drops_item_collected_while_cloud_is_matching(self):
        item = self.add_item()
        _, body = self.start(item)
        self.complete(body["operation"])
        def matching(_query, _inventory):
            _, retrieval = self.start(item, "retrieve")
            self.complete(retrieval["operation"])
            return [{"id": 1, "reason": "Keys match."}]
        with patch.object(search, "find_matches", side_effect=matching):
            status, body = self.post("/api/search", {"query": "keys"})
        self.assertEqual(status, 200)
        self.assertEqual(body["matches"], [])
        self.assertEqual(body["searched_count"], 1)

    def test_failed_pulse_stays_reserved_and_requires_explicit_resolution(self):
        self.driver.failure = RuntimeError("private device details")
        item, request_id = self.add_item(), str(uuid.uuid4())
        status, body = self.start(item, request_id=request_id)
        operation = body["operation"]
        self.assertEqual(status, 201)
        self.assertEqual(operation["state"], "uncertain")
        self.assertEqual(body["item"]["status"], "recovery")
        self.assertNotIn("private", json.dumps(body))
        self.assertEqual(self.complete(operation)[0], 409)
        self.assertEqual(self.start(item, request_id=request_id)[1], body)
        self.assertEqual(self.start(item)[0], 409)
        self.assertEqual(len(self.driver.pulses), 1)
        path = f"/api/locker-operations/{request_id}/resolve"
        self.assertEqual(self.post(path, {"outcome": "collected"})[0], 400)
        self.assertEqual(self.post(path, {"outcome": "empty"})[1]["item"]["status"], "recorded")
        self.assertEqual(self.post(path, {"outcome": "empty"})[0], 200)
        self.assertEqual(self.post(path, {"outcome": "stored"})[0], 409)
        self.assertEqual(self.complete(operation)[0], 409)

    def test_restart_restores_waiting_and_turns_interrupted_actuation_uncertain(self):
        first, second = self.add_item(), self.add_item()
        _, first_body = self.start(first)
        _, second_body = self.start(second)
        identifier = second_body["operation"]["id"]
        db = self.server.connect_db()
        with db:
            db.execute("UPDATE locker_operations SET state='actuating' WHERE id=?", (identifier,))
        db.close()
        self.stop_server()
        self.start_server()
        self.assertEqual(len(self.driver.pulses), 2)
        operations = {operation["id"]: operation for operation in self.get("/api/lockers")[1]["operations"]}
        self.assertEqual(operations[first_body["operation"]["id"]]["state"], "awaiting_confirmation")
        self.assertEqual(operations[identifier]["state"], "uncertain")
        self.assertEqual(self.start(second, request_id=identifier)[1]["operation"]["state"], "uncertain")
        self.assertEqual(len(self.driver.pulses), 2)
        self.assertEqual(self.complete(first_body["operation"])[0], 200)

    def test_retrieval_reconcile_keeps_item_or_collects_it(self):
        item = self.add_item()
        _, body = self.start(item)
        self.complete(body["operation"])
        self.driver.failure = RuntimeError("failure")
        _, body = self.start(item, "retrieve")
        path = f"/api/locker-operations/{body['operation']['id']}/resolve"
        self.assertEqual(self.post(path, {"outcome": "empty"})[0], 400)
        self.assertEqual(self.post(path, {"outcome": "stored"})[1]["item"]["status"], "stored")
        _, body = self.start(item, "retrieve")
        path = f"/api/locker-operations/{body['operation']['id']}/resolve"
        self.assertEqual(self.post(path, {"outcome": "collected"})[1]["item"]["status"], "collected")
        self.assertEqual(self.get("/api/lockers")[1]["compartments"][0]["state"], "free")

    def test_persistent_cooldown_rejects_before_new_pulse(self):
        self.driver.cooldown_seconds = 30
        item = self.add_item()
        _, body = self.start(item)
        self.complete(body["operation"])
        self.stop_server()
        self.start_server()
        self.assertEqual(self.start(item, "retrieve")[0], 429)
        self.assertEqual(len(self.driver.pulses), 1)

    def test_process_interruption_after_committed_intent_never_replays(self):
        class ProcessStopped(BaseException):
            pass
        item, request_id = self.add_item(), str(uuid.uuid4())
        self.driver.failure = ProcessStopped()
        with self.assertRaises(ProcessStopped):
            self.server.lockers.start(request_id, item, "deposit")
        db = self.server.connect_db()
        self.assertEqual(db.execute("SELECT state FROM locker_operations WHERE id=?", (request_id,)).fetchone()[0], "actuating")
        db.close()
        recovered = lockers.LockerStore(self.server.connect_db, self.directory.name, self.driver)
        operation, duplicate = recovered.start(request_id, item, "deposit")
        self.assertTrue(duplicate)
        self.assertEqual(operation["state"], "uncertain")
        self.assertEqual(len(self.driver.pulses), 1)
        self.assertEqual(recovered.snapshot()["compartments"][0]["state"], "recovery")

    def test_deposit_skips_cooling_free_slots_from_api_and_diagnostic(self):
        self.driver.name = "gpio"
        self.driver.cooldown_seconds = 30
        db = self.server.connect_db()
        with db:
            db.execute("INSERT INTO locker_pulses VALUES('01',?)", (time.time(),))
        db.close()
        (Path(self.directory.name) / "lock-test-gpio26.lock").write_text(str(time.time()))
        status, body = self.start(self.add_item())
        self.assertEqual(status, 201)
        self.assertEqual(body["operation"]["compartment_id"], "03")
        status, body = self.start(self.add_item())
        self.assertEqual(status, 201)
        self.assertEqual(body["operation"]["compartment_id"], "04")
        self.assertEqual(self.start(self.add_item())[0], 429)
        self.assertEqual(self.driver.pulses, ["03", "04"])

    def block_actuation_updates(self, include_uncertain=False):
        condition = "NEW.state IN ('awaiting_confirmation','uncertain')" if include_uncertain else "NEW.state='awaiting_confirmation'"
        db = self.server.connect_db()
        with db:
            db.execute("CREATE TRIGGER reject_actuation_update BEFORE UPDATE OF state ON locker_operations "
                       f"WHEN {condition} BEGIN SELECT RAISE(FAIL,'injected persistence error'); END")
        db.close()

    def unblock_actuation_updates(self):
        db = self.server.connect_db()
        with db:
            db.execute("DROP TRIGGER reject_actuation_update")
        db.close()

    def test_failed_post_pulse_commit_becomes_uncertain_without_restart(self):
        self.block_actuation_updates()
        item, request_id = self.add_item(), str(uuid.uuid4())
        status, body = self.start(item, request_id=request_id)
        self.assertEqual(status, 201)
        self.assertEqual(body["operation"]["state"], "uncertain")
        self.assertEqual(body["item"]["status"], "recovery")
        self.assertEqual(self.start(item, request_id=request_id)[1]["operation"]["state"], "uncertain")
        self.assertEqual(self.driver.pulses, ["01"])

    def test_abandoned_actuation_recovers_on_get_replay_and_finish(self):
        for recovery in ("get", "replay", "finish"):
            with self.subTest(recovery=recovery):
                self.block_actuation_updates(include_uncertain=True)
                item, request_id = self.add_item(), str(uuid.uuid4())
                self.assertEqual(self.start(item, request_id=request_id)[0], 500)
                self.unblock_actuation_updates()
                if recovery == "get":
                    self.assertEqual(self.get(f"/api/locker-operations/{request_id}")[1]["operation"]["state"], "uncertain")
                elif recovery == "replay":
                    self.assertEqual(self.start(item, request_id=request_id)[1]["operation"]["state"], "uncertain")
                else:
                    # An ordinary completion cannot treat a recovered operation as successful.
                    self.assertEqual(self.post(f"/api/locker-operations/{request_id}/complete")[0], 409)
                    db = self.server.connect_db()
                    self.assertEqual(db.execute("SELECT state FROM locker_operations WHERE id=?", (request_id,)).fetchone()[0], "uncertain")
                    db.close()
                self.assertEqual(self.get("/api/lockers")[1]["compartments"][0]["state"], "recovery")
                self.assertEqual(self.post(f"/api/locker-operations/{request_id}/resolve", {"outcome": "empty"})[0], 200)
        self.assertEqual(self.driver.pulses, ["01", "01", "01"])

    def test_independent_managers_share_durable_replay_and_serialization(self):
        other = lockers.LockerStore(self.server.connect_db, self.directory.name, self.driver)
        item, request_id = self.add_item(), str(uuid.uuid4())
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(manager.start, request_id, item, "deposit")
                       for manager in (self.server.lockers, other)]
            results = [future.result(3) for future in futures]
        self.assertEqual(sorted(duplicate for _, duplicate in results), [False, True])
        self.assertEqual(len(self.driver.pulses), 1)

    def test_gpio_mode_shares_diagnostic_cooldown_without_importing_hardware(self):
        self.driver.name = "gpio"  # Still an injected fake; no lgpio import or calls.
        self.driver.cooldown_seconds = 30
        item = self.add_item()
        _, body = self.start(item)
        diagnostic = Path(self.directory.name) / "lock-test-gpio17.lock"
        self.assertGreater(float(diagnostic.read_text()), 0)
        self.complete(body["operation"])
        db = self.server.connect_db()
        with db:
            db.execute("DELETE FROM locker_pulses")
        db.close()
        self.assertEqual(self.start(item, "retrieve")[0], 429)
        self.assertEqual(len(self.driver.pulses), 1)

    def test_old_completion_cannot_release_reused_compartment(self):
        item = self.add_item()
        _, body = self.start(item)
        deposit = body["operation"]
        self.complete(deposit)
        _, body = self.start(item, "retrieve")
        retrieval = body["operation"]
        self.complete(retrieval)
        next_item = self.add_item()
        self.start(next_item)
        self.assertEqual(self.complete(retrieval)[0], 200)
        self.assertEqual(self.complete(deposit)[0], 200)
        slot = self.get("/api/lockers")[1]["compartments"][0]
        self.assertEqual(slot["item_id"], next_item)
        self.assertEqual(slot["state"], "reserved")

    def test_validation_and_unrecognized_items_do_not_pulse(self):
        self.assertEqual(self.start(self.add_item(False))[0], 409)
        self.assertEqual(self.start(str(uuid.uuid4()))[0], 404)
        self.assertEqual(self.start("not-a-uuid")[0], 400)
        self.assertEqual(self.start(self.add_item(), "bad")[0], 400)
        self.assertEqual(self.post("/api/locker-operations", {}, {"X-Requested-With": ""})[0], 403)
        self.assertEqual(self.post("/api/locker-operations", {}, {"Origin": "https://evil.test"})[0], 403)
        self.assertEqual(self.post("/api/locker-operations", {})[0], 400)
        self.assertEqual(self.get("/api/locker-operations/not-a-uuid")[0], 400)
        self.assertEqual(self.get("/api/locker-operations/" + str(uuid.uuid4()))[0], 404)
        self.assertEqual(self.driver.pulses, [])

    def test_ownership_mismatch_fails_closed(self):
        _, body = self.start(self.add_item())
        db = self.server.connect_db()
        for item_id, state in ((None, "reserved"), (body["item"]["id"], "free"), (body["item"]["id"], "occupied")):
            with db:
                db.execute("UPDATE compartments SET item_id=?,state=? WHERE id='01'", (item_id, state))
            self.assertEqual(self.complete(body["operation"])[0], 409)
        db.close()

    def test_disabled_mode_retains_records_and_never_actuates(self):
        self.stop_server()
        self.driver = None
        self.start_server()
        status, body = self.get("/api/lockers")
        self.assertEqual(status, 200)
        self.assertFalse(body["enabled"])
        self.assertEqual(body["driver"], "disabled")
        self.assertEqual(self.start(self.add_item())[0], 503)

    def test_disabling_hardware_does_not_restore_collected_or_pending_search_results(self):
        legacy, stored, collected, pending = [self.add_item() for _ in range(4)]
        for item in (stored, collected):
            _, body = self.start(item)
            self.complete(body["operation"])
        _, body = self.start(collected, "retrieve")
        self.complete(body["operation"])
        self.start(pending)
        driver = self.driver
        pulses = list(driver.pulses)
        self.stop_server()
        self.driver = None
        self.start_server()
        with patch.object(search, "find_matches", return_value=[
                {"id": 1, "reason": "Keys."}, {"id": 2, "reason": "Keys."}]) as provider:
            status, body = self.post("/api/search", {"query": "keys"})
        self.assertEqual(status, 200)
        self.assertEqual(body["searched_count"], 2)
        self.assertEqual({match["item"]["id"] for match in body["matches"]}, {legacy, stored})
        self.assertEqual(len(provider.call_args.args[1]), 2)
        self.assertEqual(self.get("/api/items?available=1")[1]["total"], 1)
        self.assertEqual(self.get("/api/items")[1]["total"], 4)
        self.assertEqual(self.start(stored, "retrieve")[0], 503)
        self.assertEqual(driver.pulses, pulses)


class GPIODriverTests(unittest.TestCase):
    def api(self):
        class GPIOError(Exception):
            def __init__(self, value):
                self.value = value
        api = Mock()
        api.SET_PULL_DOWN = 16
        api.TX_PWM = 0
        api.BAD_PWM_MICROS = -86
        api.error = GPIOError
        api.error_text.return_value = "bad PWM micros"
        api.gpiochip_open.return_value = 1
        api.gpio_get_chip_info.return_value = [0, 58, "gpiochip0", "pinctrl-bcm2711"]
        api.gpio_get_line_info.side_effect = lambda handle, pin: [0, pin, 0, f"GPIO{pin}", ""]
        return api

    def test_preflight_is_read_only_and_checks_all_four_lines(self):
        api = self.api()
        lockers.GPIODriver(lockers.GPIO_MAP, api).preflight()
        self.assertEqual(api.gpio_get_line_info.call_count, 4)
        api.gpio_claim_output.assert_not_called()
        api.tx_pulse.assert_not_called()
        api.gpiochip_close.assert_called_once_with(1)

    def test_pulse_is_one_finite_high_and_cleans_to_low_on_every_channel(self):
        for compartment, gpio in lockers.GPIO_MAP.items():
            with self.subTest(compartment=compartment):
                api = self.api()
                api.tx_busy.side_effect = [1, 0]
                api.gpio_read.side_effect = [1, 0]
                with patch.object(lockers.time, "sleep"):
                    lockers.GPIODriver(lockers.GPIO_MAP, api).pulse(compartment)
                api.gpio_claim_output.assert_called_once_with(1, gpio, 0, api.SET_PULL_DOWN)
                self.assertEqual(api.tx_pulse.call_args_list[0].args, (1, gpio, 500_000, 50_000, 0, 1))
                self.assertEqual(api.tx_pulse.call_count, 2)
                self.assertTrue(all(call.args == (1, gpio, 0) for call in api.gpio_write.call_args_list))
                api.gpio_free.assert_called_once_with(1, gpio)
                api.gpiochip_close.assert_called_once_with(1)

    def test_failure_stops_pulse_and_lowers_output_without_retry(self):
        api = self.api()
        api.tx_busy.side_effect = RuntimeError("failure")
        with self.assertRaises(RuntimeError):
            lockers.GPIODriver(lockers.GPIO_MAP, api).pulse("01")
        self.assertEqual(api.tx_pulse.call_count, 2)
        api.gpio_write.assert_called_once_with(1, 17, 0)
        api.gpio_free.assert_called_once_with(1, 17)
        api.gpiochip_close.assert_called_once_with(1)

    def test_busy_or_wrong_chip_cannot_claim_gpio(self):
        for problem in ("chip", "busy"):
            api = self.api()
            if problem == "chip":
                api.gpio_get_chip_info.return_value = [0, 58, "gpiochip0", "unknown"]
            else:
                api.gpio_get_line_info.side_effect = lambda handle, pin: [0, pin, 0, f"GPIO{pin}", "other"]
            with self.assertRaises(RuntimeError):
                lockers.GPIODriver(lockers.GPIO_MAP, api).pulse("01")
            api.gpio_claim_output.assert_not_called()
            api.tx_pulse.assert_not_called()
            api.gpiochip_close.assert_called_once_with(1)

    def test_timeout_and_missing_high_fail_closed_with_cleanup(self):
        for timeout in (False, True):
            api = self.api()
            api.tx_busy.return_value = 1 if timeout else 0
            api.gpio_read.return_value = 0
            with patch.object(lockers.time, "monotonic", side_effect=[0, 2]):
                with self.assertRaises((RuntimeError, TimeoutError)):
                    lockers.GPIODriver(lockers.GPIO_MAP, api).pulse("01")
            api.gpio_write.assert_called_with(1, 17, 0)
            api.gpio_free.assert_called_once_with(1, 17)
            api.gpiochip_close.assert_called_once_with(1)

    def test_claim_failure_and_stop_failure_still_close_resources(self):
        api = self.api()
        api.gpio_claim_output.side_effect = RuntimeError("busy")
        with self.assertRaises(RuntimeError):
            lockers.GPIODriver(lockers.GPIO_MAP, api).pulse("01")
        api.tx_pulse.assert_not_called()
        api.gpio_write.assert_not_called()
        api.gpio_free.assert_not_called()
        api.gpiochip_close.assert_called_once_with(1)

        api = self.api()
        api.tx_busy.side_effect = [1, 0]
        api.gpio_read.side_effect = [1, 0]
        api.tx_pulse.side_effect = [None, RuntimeError("stop failure")]
        with patch.object(lockers.time, "sleep"), self.assertRaises(RuntimeError):
            lockers.GPIODriver(lockers.GPIO_MAP, api).pulse("01")
        api.gpio_write.assert_called_with(1, 17, 0)
        api.gpio_free.assert_called_once_with(1, 17)
        api.gpiochip_close.assert_called_once_with(1)

    def test_configuration_requires_explicit_mode_map_and_local_simulation(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(lockers.configured_driver("127.0.0.1"))
            with self.assertRaises(ValueError):
                lockers.configured_driver("0.0.0.0", "simulated")
            with self.assertRaises(ValueError):
                lockers.configured_driver("127.0.0.1", "gpio")
            with self.assertRaises(ValueError):
                lockers.GPIODriver({"01": 17}, self.api())
            self.assertEqual(lockers.configured_driver("127.0.0.1", "simulated").name, "simulated")


if __name__ == "__main__":
    unittest.main()
