"""Door feedback gates visitor completion while preserving staff and replay flows."""

import threading
import unittest
from unittest.mock import patch
import uuid

import door_feedback
import test_admin
from test_door_feedback import FakeGPIO
from test_vibration import FakeClock


class DoorFeedbackHTTPTests(unittest.TestCase):
    request = test_admin.AdminHTTPTests.request
    stop_server = test_admin.AdminHTTPTests.stop_server
    get = test_admin.AdminHTTPTests.get
    post = test_admin.AdminHTTPTests.post
    login = test_admin.AdminHTTPTests.login
    add_item = test_admin.AdminHTTPTests.add_item
    tearDown = test_admin.AdminHTTPTests.tearDown

    def setUp(self):
        test_admin.AdminHTTPTests.setUp(self)
        self.server.door_feedback.close()
        self.clock = FakeClock()
        self.gpio = FakeGPIO(level=1)
        self.monitor = door_feedback.DoorFeedbackMonitor(
            enabled=True, api=self.gpio, clock=self.clock, wall_clock=self.clock.wall)
        self.server.door_feedback = self.monitor
        self.server.lockers.door_monitor = self.monitor
        with patch.object(threading.Thread, "start"):
            self.monitor.start()
        self.sample(1, .25)

    def sample(self, level, seconds=0):
        self.clock.advance(seconds)
        self.gpio.level = level
        self.monitor._sample()

    def closed(self):
        self.sample(0)
        self.sample(0, .25)

    def start(self, item=None, kind="deposit"):
        status, _, body = self.post("/api/locker-operations", {
            "request_id": str(uuid.uuid4()), "item_id": item or self.add_item(), "kind": kind})
        self.assertEqual(status, 201)
        return body

    def complete(self, operation):
        return self.post(f"/api/locker-operations/{operation['id']}/complete")

    def state_rows(self):
        db = self.server.connect_db()
        try:
            return {table: [tuple(row) for row in db.execute(f"SELECT * FROM {table} ORDER BY rowid")]
                    for table in ("items", "item_storage", "compartments", "locker_operations", "locker_pulses")}
        finally:
            db.close()

    def test_public_admin_and_operation_reads_share_real_input_and_do_not_pulse(self):
        body = self.start()
        self.login()
        public = self.get("/api/lockers")[2]
        admin = self.get("/api/admin/overview")[2]
        operation = self.get(f"/api/locker-operations/{body['operation']['id']}")[2]["operation"]
        expected = self.monitor.snapshot("01")
        self.assertEqual(body["operation"]["door"], expected)
        self.assertEqual(operation["door"], expected)
        self.assertEqual(public["compartments"][0]["door"], expected)
        self.assertEqual(public["operations"][0]["door"], expected)
        self.assertEqual(admin["lockers"]["compartments"][0]["door"], expected)
        self.assertEqual(admin["lockers"]["operations"][0]["door"], expected)
        self.assertEqual(admin["lockers"]["compartments"][0]["door_state"], "open")
        self.assertTrue(admin["capabilities"]["door_sensor"])
        self.assertTrue(admin["capabilities"]["physical_feedback"])
        self.assertEqual(admin["lockers"]["compartments"][1]["door"], self.monitor.snapshot("02"))
        for slot in admin["lockers"]["compartments"][2:]:
            self.assertEqual(slot["door"], door_feedback.not_configured())
        self.assertEqual(self.driver.pulses, ["01"])

    def test_deposit_requires_stable_closed_without_automatic_inventory_change(self):
        body = self.start()
        operation = body["operation"]
        before = self.state_rows()
        self.assertEqual(self.complete(operation)[0], 409)
        self.assertEqual(self.state_rows(), before)
        self.sample(0)
        self.assertEqual(self.complete(operation)[0], 409)
        self.assertEqual(self.state_rows(), before)
        self.sample(0, .25)
        self.assertEqual(self.state_rows(), before, "Closure alone must not complete a transfer")
        status, _, result = self.complete(operation)
        self.assertEqual(status, 200)
        self.assertEqual(result["item"]["status"], "stored")
        self.assertEqual(result["operation"]["door"]["state"], "closed")
        completed = self.state_rows()
        self.sample(1)
        self.sample(1, .25)
        self.assertEqual(self.complete(operation)[0], 200, "An idempotent replay ignores later door movement")
        self.assertEqual(self.state_rows(), completed)
        self.assertEqual(self.driver.pulses, ["01"])

    def test_retrieval_keeps_slot_reserved_until_closed_and_confirmed(self):
        body = self.start()
        self.closed()
        self.assertEqual(self.complete(body["operation"])[0], 200)
        retrieval = self.start(body["item"]["id"], "retrieve")
        self.sample(1)
        self.sample(1, .25)
        before = self.state_rows()
        self.assertEqual(self.complete(retrieval["operation"])[0], 409)
        self.assertEqual(self.state_rows(), before)
        self.closed()
        status, _, result = self.complete(retrieval["operation"])
        self.assertEqual(status, 200)
        self.assertEqual(result["item"]["status"], "collected")
        self.assertEqual(self.get("/api/lockers")[2]["compartments"][0]["state"], "free")
        self.assertEqual(self.driver.pulses, ["01", "01"])

    def test_stale_or_failed_feedback_rejects_completion_without_mutating_inventory(self):
        body = self.start()
        self.closed()
        before = self.state_rows()
        self.clock.advance(1)
        self.assertEqual(self.complete(body["operation"])[0], 503)
        self.assertEqual(self.state_rows(), before)
        self.monitor._fail()
        self.assertEqual(self.complete(body["operation"])[0], 503)
        self.assertEqual(self.state_rows(), before)
        self.assertEqual(self.get("/api/lockers")[2]["compartments"][0]["door"]["state"], "unavailable")
        self.assertEqual(self.driver.pulses, ["01"])

    def test_compartments_without_contacts_retain_manual_confirmation(self):
        self.start()  # Keep 01 reserved with its door open.
        self.start()  # Keep 02 reserved with its independent door open.
        for compartment in ("03", "04"):
            body = self.start()
            operation = body["operation"]
            self.assertEqual(operation["compartment_id"], compartment)
            self.assertEqual(operation["door"], door_feedback.not_configured())
            self.assertEqual(self.complete(operation)[0], 200)
        self.assertEqual(self.driver.pulses, ["01", "02", "03", "04"])

    def test_second_door_gates_its_own_deposit_and_collection(self):
        first = self.start()
        second = self.start()
        operation = second["operation"]
        self.assertEqual((operation["compartment_id"], operation["door"]["gpio"], operation["door"]["pin"]), ("02", 18, 12))
        self.gpio.levels[12] = 0
        self.sample(1)
        self.sample(1, .25)
        self.assertEqual(self.monitor.snapshot("01")["state"], "closed")
        before = self.state_rows()
        self.assertEqual(self.complete(operation)[0], 409, "Closing 01 cannot complete 02")
        self.assertEqual(self.state_rows(), before)
        self.gpio.levels = {12: 1, 18: 0}
        self.sample(1)
        self.sample(1, .25)
        self.assertEqual(self.complete(operation)[0], 200, "02 can finish while 01 remains open")
        self.assertEqual(self.complete(first["operation"])[0], 409)
        collection = self.start(second["item"]["id"], "retrieve")
        self.gpio.levels[18] = 1
        self.sample(1)
        self.sample(1, .25)
        before = self.state_rows()
        self.assertEqual(self.complete(collection["operation"])[0], 409)
        self.assertEqual(self.state_rows(), before)
        self.gpio.levels[18] = 0
        self.sample(1)
        self.sample(1, .25)
        status, _, completed = self.complete(collection["operation"])
        self.assertEqual(status, 200)
        self.assertEqual(completed["item"]["status"], "collected")
        self.assertEqual(self.get("/api/lockers")[2]["compartments"][1]["state"], "free")
        self.assertEqual(self.driver.pulses, ["01", "02", "02"])

    def test_staff_resolution_remains_available_when_feedback_fails(self):
        self.login()
        body = self.start()
        self.monitor._fail()
        path = f"/api/admin/locker-operations/{body['operation']['id']}/resolve"
        status, _, result = self.post(path, {"outcome": "stored"})
        self.assertEqual(status, 200)
        self.assertEqual(result["item"]["status"], "stored")
        self.assertEqual(result["operation"]["door"]["state"], "unavailable")
        self.assertEqual(self.complete(body["operation"])[0], 200)
        self.assertEqual(self.driver.pulses, ["01"])

    def test_manual_open_stays_available_and_does_not_change_inventory(self):
        self.login()
        before = self.state_rows()
        self.monitor._fail()
        status, _, result = self.post("/api/admin/manual-open", {
            "request_id": str(uuid.uuid4()), "compartment_id": "01"})
        self.assertEqual(status, 201)
        self.assertEqual(result["operation"]["state"], "completed")
        after = self.state_rows()
        for table in ("items", "item_storage", "compartments", "locker_operations"):
            self.assertEqual(after[table], before[table])
        self.assertEqual(self.driver.pulses, ["01"])


if __name__ == "__main__":
    unittest.main()
