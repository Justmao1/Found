"""Staff HTTP contracts with temporary credentials and simulated physical outputs."""

import http.client
from http.cookies import SimpleCookie
import json
import os
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.parse import urlencode
import uuid

import iot_admin
import test_lockers
import test_server
import vision


PASSWORD = "fixture-only-admin-password"


class AdminHTTPTests(unittest.TestCase):
    request = test_server.PhotoServerTests.request
    stop_server = test_server.PhotoServerTests.stop_server
    add_item = test_lockers.LockerHTTPTests.add_item

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.password_file = Path(self.directory.name) / "password.txt"
        self.password_file.write_text(PASSWORD, encoding="utf-8")
        self.environment = patch.dict(os.environ, {
            "LOST_FOUND_ADMIN_PASSWORD_FILE": str(self.password_file),
            "LOST_FOUND_AI_CONFIG": str(Path(self.directory.name) / "absent-ai.json"),
            "DASHSCOPE_API_KEY": "", "LOST_FOUND_LOCKER_MODE": "disabled",
        })
        self.environment.start()
        self.no_cloud = patch.object(vision, "recognize", side_effect=AssertionError("Unexpected cloud call"))
        self.no_cloud.start()
        self.driver = test_lockers.FakeDriver()
        self.server = test_server.server_module.build_server(
            "127.0.0.1", 0, Path(self.directory.name) / "data", auto_recognize=False, locker_driver=self.driver)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.cookie = None

    def tearDown(self):
        self.stop_server()
        self.no_cloud.stop()
        self.environment.stop()
        self.directory.cleanup()

    def get(self, path, cookie=None):
        chosen = self.cookie if cookie is None else cookie
        headers = {"Cookie": chosen} if chosen else {}
        status, headers, raw = self.request("GET", path, headers=headers)
        return status, headers, json.loads(raw)

    def post(self, path, payload=None, headers=None, cookie=None):
        chosen = self.cookie if cookie is None else cookie
        request_headers = {"Content-Type": "application/json", "X-Requested-With": "lost-found-box"}
        if chosen:
            request_headers["Cookie"] = chosen
        request_headers.update(headers or {})
        status, headers, raw = self.request(
            "POST", path, json.dumps({} if payload is None else payload).encode(), request_headers)
        return status, headers, json.loads(raw)

    def login(self):
        status, headers, body = self.post("/api/admin/login", {"password": PASSWORD})
        self.assertEqual(status, 200)
        self.assertEqual(body, {"authenticated": True})
        self.cookie = headers["Set-Cookie"].split(";", 1)[0]
        return headers

    def manual_payload(self, compartment="01", reason="检查铰链，物品保持不变"):
        return {"request_id": str(uuid.uuid4()), "compartment_id": compartment, "reason": reason}

    def store_item(self, identifier):
        status, _, body = self.post("/api/locker-operations", {
            "request_id": str(uuid.uuid4()), "item_id": identifier, "kind": "deposit"})
        self.assertEqual(status, 201)
        self.assertEqual(self.post(f"/api/locker-operations/{body['operation']['id']}/complete")[0], 200)
        return body["operation"]

    def test_login_cookie_session_rotation_logout_and_expiry(self):
        self.assertEqual(self.get("/api/admin/session")[2], {"configured": True, "authenticated": False})
        headers = self.login()
        self.assertIn("HttpOnly", headers["Set-Cookie"])
        self.assertIn("SameSite=Strict", headers["Set-Cookie"])
        self.assertIn("Path=/api/admin", headers["Set-Cookie"])
        self.assertNotIn("Secure", headers["Set-Cookie"], "This fixture is loopback HTTP")
        self.assertEqual(headers["Cache-Control"], "no-store")
        first = self.cookie
        self.assertTrue(self.get("/api/admin/session")[2]["authenticated"])
        self.login()
        self.assertNotEqual(first, self.cookie)
        self.assertFalse(self.get("/api/admin/session", cookie=first)[2]["authenticated"])
        token = self.server.admin.sessions.token(self.cookie)
        with self.server.admin.sessions.lock:
            self.server.admin.sessions.tokens[token] = 0
        self.assertFalse(self.get("/api/admin/session")[2]["authenticated"])
        self.assertEqual(self.get("/api/admin/items")[0], 401)
        self.login()
        status, headers, body = self.post("/api/admin/logout")
        self.assertEqual((status, body), (200, {"authenticated": False}))
        self.assertIn("Max-Age=0", headers["Set-Cookie"])
        self.assertFalse(self.get("/api/admin/session")[2]["authenticated"])
        self.assertEqual(self.driver.pulses, [])

    def test_protected_endpoints_reject_missing_forged_or_expired_session(self):
        identifier = str(uuid.uuid4())
        for cookie in ("", "found_admin=forged", "found_admin=\"unterminated"):
            for path in ("/api/admin/overview", "/api/admin/items", f"/api/admin/manual-open/{identifier}"):
                with self.subTest(cookie=cookie, path=path):
                    self.assertEqual(self.get(path, cookie=cookie)[0], 401)
            for path, payload in (
                ("/api/admin/manual-open", self.manual_payload()),
                (f"/api/admin/manual-open/{identifier}/confirm", {}),
                (f"/api/admin/locker-operations/{identifier}/resolve", {"outcome": "empty"}),
                (f"/api/admin/items/{identifier}/recognize", {}),
                ("/api/admin/logout", {}),
            ):
                self.assertEqual(self.post(path, payload, cookie=cookie)[0], 401)
        self.assertEqual(self.driver.pulses, [])
        self.assertEqual(self.server.ai_queue.qsize(), 0)

    def test_login_validation_wrong_password_and_unconfigured_service(self):
        for payload in ({}, {"password": PASSWORD, "extra": True}, {"password": None},
                        {"password": ""}, {"password": "x" * 257}, {"password": "\ud800"}):
            with self.subTest(payload=repr(payload)):
                self.assertEqual(self.post("/api/admin/login", payload)[0], 400)
        status, headers, body = self.post("/api/admin/login", {"password": "incorrect-fixture"})
        self.assertEqual(status, 401)
        self.assertNotIn("Set-Cookie", headers)
        self.assertNotIn(PASSWORD, json.dumps(body))
        self.server.admin.sessions.password_hash = None
        self.assertEqual(self.get("/api/admin/session")[2], {"configured": False, "authenticated": False})
        self.assertEqual(self.post("/api/admin/login", {"password": PASSWORD})[0], 503)

    def test_origin_header_content_type_size_and_json_guards_precede_mutations(self):
        self.assertEqual(self.post("/api/admin/login", {"password": PASSWORD}, {"X-Requested-With": ""})[0], 403)
        self.login()
        payload = self.manual_payload()
        cases = [({"Origin": "https://evil.invalid"}, 403),
                 ({"Origin": f"http://127.0.0.1:{self.server.server_port}/path"}, 403),
                 ({"X-Requested-With": ""}, 403),
                 ({"Content-Type": "text/plain"}, 415),
                 ({"Content-Length": "16385"}, 413),
                 ({"Content-Length": "-1"}, 400),
                 ({"Transfer-Encoding": "chunked"}, 400)]
        for headers, expected in cases:
            with self.subTest(headers=headers):
                self.assertEqual(self.post("/api/admin/manual-open", payload, headers)[0], expected)
        headers = {"Cookie": self.cookie, "Content-Type": "application/json", "X-Requested-With": "lost-found-box"}
        for raw in (b"{", b"[]", b"null", b"\xff"):
            self.assertEqual(self.request("POST", "/api/admin/manual-open", raw, headers)[0], 400)
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        try:
            connection.putrequest("POST", "/api/admin/logout")
            for key, value in headers.items():
                connection.putheader(key, value)
            connection.putheader("Content-Length", "2")
            connection.putheader("Content-Length", "2")
            connection.endheaders(b"{}")
            response = connection.getresponse()
            self.assertEqual(response.status, 400)
            response.read()
        finally:
            connection.close()
        self.assertTrue(self.get("/api/admin/session")[2]["authenticated"])
        self.assertEqual(self.driver.pulses, [])

    def test_strict_admin_payloads_and_identifiers_cannot_pulse_or_queue(self):
        self.login()
        payload = self.manual_payload()
        invalid = [dict(payload, extra=True), {"request_id": payload["request_id"]},
                   dict(payload, request_id="bad"), dict(payload, request_id=payload["request_id"].upper()),
                   dict(payload, compartment_id="05"), dict(payload, compartment_id=[]),
                   dict(payload, reason=" "), dict(payload, reason="x" * 201), dict(payload, reason="\ud800")]
        for value in invalid:
            self.assertEqual(self.post("/api/admin/manual-open", value)[0], 400)
        identifier = str(uuid.uuid4())
        for path, body in ((f"/api/admin/manual-open/{identifier}/confirm", {"done": True}),
                           (f"/api/admin/locker-operations/{identifier}/resolve", {"outcome": None}),
                           (f"/api/admin/locker-operations/{identifier}/resolve", {"outcome": "empty", "extra": 1}),
                           (f"/api/admin/items/{identifier}/recognize", {"force": True}),
                           ("/api/admin/logout", {"extra": True})):
            self.assertEqual(self.post(path, body)[0], 400)
        self.assertEqual(self.get("/api/admin/manual-open/not-a-uuid")[0], 400)
        self.assertEqual(self.get(f"/api/admin/manual-open/{identifier}")[0], 404)
        self.assertEqual(self.post(f"/api/admin/items/{identifier}/recognize")[0], 404)
        self.assertEqual(self.driver.pulses, [])
        self.assertEqual(self.server.ai_queue.qsize(), 0)

    def test_inventory_pagination_status_and_literal_query_escaping(self):
        self.login()
        identifiers = [self.add_item() for _ in range(4)]
        notes = ["<script>alert('fixture')</script> 100%_match\\", "Blue bottle", "silver case", "plain"]
        db = self.server.connect_db()
        with db:
            for identifier, note in zip(identifiers, notes):
                db.execute("UPDATE items SET note=? WHERE id=?", (note, identifier))
        db.close()
        self.store_item(identifiers[1])
        status, headers, page = self.get("/api/admin/items?limit=2&offset=1")
        self.assertEqual(status, 200)
        self.assertEqual((page["total"], page["offset"], page["limit"]), (4, 1, 2))
        self.assertEqual([item["id"] for item in page["items"]], list(reversed(identifiers))[1:3])
        self.assertIn("application/json", headers["Content-Type"])
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        for term in ("%", "_", "\\", "<script>", identifiers[0]):
            with self.subTest(term=term):
                result = self.get("/api/admin/items?" + urlencode({"q": term}))[2]
                self.assertEqual([item["id"] for item in result["items"]], [identifiers[0]])
                self.assertEqual(result["items"][0]["note"], notes[0], "JSON data is preserved, not rendered as HTML")
                self.assertEqual(result["items"][0]["image_url"], "/images/" + identifiers[0])
        self.assertEqual(self.get("/api/admin/items?" + urlencode({"q": "' OR 1=1 --"}))[2]["total"], 0)
        stored = self.get("/api/admin/items?status=stored")[2]
        self.assertEqual([item["id"] for item in stored["items"]], [identifiers[1]])
        self.assertEqual(self.get("/api/admin/items?status=recorded")[2]["total"], 3)
        self.assertEqual(self.get("/api/admin/items?q=keys")[2]["total"], 4)
        self.assertEqual(self.get("/api/admin/items?offset=100")[2]["items"], [])

    def test_inventory_searches_decoded_tags_not_recognition_metadata(self):
        self.login()
        tagged, malformed = self.add_item(), self.add_item()
        db = self.server.connect_db()
        with db:
            db.execute("UPDATE recognitions SET result=? WHERE item_id=?", (json.dumps({
                "tags": ["Blue bottle", "蓝色", "100%_tag"],
                "model": "fixture-model-metadata-only", "version": 3,
            }), tagged))
            db.execute("UPDATE recognitions SET result=? WHERE item_id=?", ("not valid json", malformed))
        db.close()
        for term in ("Blue bottle", "蓝色", "%_tag"):
            with self.subTest(term=term):
                status, _, page = self.get("/api/admin/items?" + urlencode({"q": term}))
                self.assertEqual(status, 200)
                self.assertEqual([item["id"] for item in page["items"]], [tagged])
        for term in ("fixture-model-metadata-only", "version", "not valid json"):
            with self.subTest(metadata=term):
                status, _, page = self.get("/api/admin/items?" + urlencode({"q": term}))
                self.assertEqual(status, 200)
                self.assertEqual(page["total"], 0)
        self.assertEqual(self.driver.pulses, [])

    def test_inventory_rejects_invalid_filters_and_duplicate_parameters(self):
        self.login()
        queries = ["unknown=1", "q=a&q=b", "status=stored&status=recorded", "status=maintenance",
                   "status=all", "limit=0", "limit=101", "limit=1.5", "offset=-1", "offset=10000001",
                   "offset=not-a-number", "limit=1&limit=2", urlencode({"q": "x" * 201})]
        for query in queries:
            with self.subTest(query=query):
                self.assertEqual(self.get("/api/admin/items?" + query)[0], 400)
        self.assertEqual(self.driver.pulses, [])

    def test_overview_uses_real_disk_and_null_unsupported_metrics_without_secrets_or_pulses(self):
        self.login()
        first, second = self.add_item(), self.add_item(False)
        self.store_item(first)
        before = list(self.driver.pulses)
        with patch.object(iot_admin, "linux_counters", return_value=(None, None, None, None, None)), \
                patch.object(iot_admin.Telemetry, "refresh_addresses", return_value=None), \
                patch.object(iot_admin.subprocess, "run", side_effect=AssertionError("Read must not invoke physical control")):
            status, headers, body = self.get("/api/admin/overview")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(body["refresh_interval_seconds"], 3)
        self.assertIsNone(body["metrics"]["cpu_percent"])
        self.assertIsNone(body["metrics"]["memory"]["percent"])
        self.assertIsNone(body["metrics"]["cpu_temperature_celsius"])
        self.assertIsNone(body["metrics"]["network"]["rx_bytes_per_second"])
        self.assertIsNone(body["device"]["system_uptime_seconds"])
        self.assertGreater(body["metrics"]["disk"]["total_bytes"], 0)
        self.assertEqual(body["inventory"]["total"], 2)
        self.assertEqual(body["inventory"]["stored"], 1)
        self.assertEqual(body["inventory"]["recorded"], 1)
        self.assertEqual(body["capabilities"], {"door_sensor": False, "physical_feedback": False})
        slots = body["lockers"]["compartments"]
        self.assertEqual([(slot["gpio"], slot["pin"]) for slot in slots], [(17, 11), (26, 37), (13, 33), (5, 29)])
        self.assertTrue(all(slot["door_state"] == "unknown" and slot["output_level"] is None for slot in slots))
        self.assertEqual(slots[0]["item"]["id"], first)
        self.assertIsNone(slots[1]["item"])
        raw = json.dumps(body)
        for secret in (PASSWORD, self.cookie, str(self.password_file), "password_hash", "api_key"):
            self.assertNotIn(secret, raw)
        self.assertEqual(self.driver.pulses, before)
        self.assertEqual(self.server.ai_queue.qsize(), 0)

    def test_manual_open_get_replay_and_confirm_preserve_stored_inventory(self):
        self.login()
        item = self.add_item()
        original = self.store_item(item)
        payload = self.manual_payload()
        status, _, body = self.post("/api/admin/manual-open", payload)
        self.assertEqual(status, 201)
        self.assertFalse(body["duplicate"])
        operation = body["operation"]
        self.assertEqual(operation["id"], payload["request_id"])
        self.assertEqual(operation["state"], "awaiting_confirmation")
        self.assertEqual(operation["item_id"], item)
        self.assertEqual(self.get("/api/items?available=1")[2]["total"], 0)
        overview = self.get("/api/admin/overview")[2]
        self.assertEqual(overview["lockers"]["compartments"][0]["state"], "maintenance")
        self.assertEqual(overview["lockers"]["compartments"][0]["item"]["status"], "stored")
        self.assertEqual(overview["manual_operations"][0]["id"], operation["id"])
        self.assertEqual(self.get(f"/api/admin/manual-open/{operation['id']}")[2]["operation"], operation)
        status, _, replay = self.post("/api/admin/manual-open", payload)
        self.assertEqual(status, 200)
        self.assertTrue(replay["duplicate"])
        self.assertEqual(replay["operation"], operation)
        self.assertEqual(self.post("/api/admin/manual-open", dict(payload, reason="Different purpose"))[0], 409)
        self.assertEqual(self.post("/api/admin/manual-open", self.manual_payload())[0], 409)
        path = f"/api/admin/manual-open/{operation['id']}/confirm"
        self.assertEqual(self.post(path)[2]["operation"]["state"], "completed")
        self.assertEqual(self.post(path)[0], 200)
        available = self.get("/api/items?available=1")[2]
        self.assertEqual(available["total"], 1)
        self.assertEqual(available["items"][0]["status"], "stored")
        self.assertEqual(self.get(f"/api/locker-operations/{original['id']}")[2]["operation"]["state"], "completed")
        self.assertEqual(self.driver.pulses, ["01", "01"])

    def test_manual_open_on_free_compartment_restores_free_without_creating_inventory(self):
        self.login()
        payload = self.manual_payload("04")
        status, _, body = self.post("/api/admin/manual-open", payload)
        self.assertEqual(status, 201)
        self.assertIsNone(body["operation"]["item_id"])
        path = f"/api/admin/manual-open/{body['operation']['id']}/confirm"
        self.assertEqual(self.post(path)[0], 200)
        self.assertEqual(self.get("/api/admin/items")[2]["total"], 0)
        slot = self.get("/api/lockers")[2]["compartments"][3]
        self.assertEqual(slot, {"id": "04", "state": "free", "item_id": None})
        self.assertEqual(self.driver.pulses, ["04"])

    def test_manual_confirmation_rejects_active_pulse_and_uncertain_response_is_safe(self):
        self.login()
        payload = self.manual_payload()
        path = f"/api/admin/manual-open/{payload['request_id']}/confirm"
        observed = []
        def during_pulse():
            observed.append(self.get(f"/api/admin/manual-open/{payload['request_id']}")[2]["operation"]["state"])
            observed.append(self.post(path)[0])
        self.driver.before_pulse = during_pulse
        self.driver.failure = RuntimeError("fixture private device detail")
        status, _, result = self.post("/api/admin/manual-open", payload)
        self.assertEqual(observed, ["actuating", 409])
        self.assertEqual(status, 201)
        self.assertEqual(result["operation"]["state"], "uncertain")
        self.assertNotIn("private device", json.dumps(result))
        self.assertEqual(self.post("/api/admin/manual-open", payload)[0], 200)
        self.assertEqual(self.post(path)[2]["operation"]["state"], "completed")
        self.assertEqual(self.driver.pulses, ["01"])

    def test_admin_reconciliation_wraps_existing_visitor_state_without_another_pulse(self):
        item = self.add_item()
        self.driver.failure = RuntimeError("fixture failure")
        _, _, result = self.post("/api/locker-operations", {
            "request_id": str(uuid.uuid4()), "item_id": item, "kind": "deposit"})
        path = f"/api/admin/locker-operations/{result['operation']['id']}/resolve"
        self.assertEqual(self.post(path, {"outcome": "empty"})[0], 401)
        self.login()
        self.assertEqual(self.post(path, {"outcome": "collected"})[0], 400)
        status, _, resolved = self.post(path, {"outcome": "empty"})
        self.assertEqual(status, 200)
        self.assertEqual(resolved["item"]["status"], "recorded")
        self.assertIsNone(resolved["item"]["compartment_id"])
        self.assertEqual(self.driver.pulses, ["01"])

    def test_recognition_retry_uses_existing_bounded_queue_and_deduplicates_pending_item(self):
        self.login()
        items = [self.add_item(False) for _ in range(66)]
        started, release = threading.Event(), threading.Event()
        calls = []
        def recognize(_image, _mime):
            calls.append(True)
            started.set()
            if not release.wait(10):
                raise AssertionError("Fixture recognition release timed out")
            return {"tags": ["keys"], "model": "fixture", "version": 3}
        with patch.object(vision, "configuration_status", return_value={"configured": True}), \
                patch.object(vision, "recognize", side_effect=recognize):
            try:
                path = f"/api/admin/items/{items[0]}/recognize"
                status, _, queued = self.post(path)
                self.assertEqual((status, queued), (202, {"queued": True, "item_id": items[0]}))
                self.assertTrue(started.wait(3))
                self.assertEqual(self.post(path)[0], 202)
                self.assertEqual(len(calls), 1)
                for item in items[1:65]:
                    self.assertEqual(self.post(f"/api/admin/items/{item}/recognize")[0], 202)
                self.assertEqual(self.server.ai_queue.qsize(), 64)
                self.assertEqual(self.post(f"/api/admin/items/{items[65]}/recognize")[0], 503)
                self.assertEqual(len(self.server.ai_pending), 65)
            finally:
                release.set()
                self.server.ai_queue.join()
        self.assertEqual(len(calls), 65)
        self.assertEqual(self.get("/api/admin/items")[2]["total"], 66)
        self.assertEqual(self.driver.pulses, [])


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        path = Path(self.directory.name) / "password.txt"
        path.write_text(PASSWORD, encoding="utf-8")
        self.environment = patch.dict(os.environ, {"LOST_FOUND_ADMIN_PASSWORD_FILE": str(path)})
        self.environment.start()
        self.sessions = iot_admin.Sessions()

    def tearDown(self):
        self.environment.stop()
        self.directory.cleanup()

    def test_https_cookie_flags_and_bounded_session_expiration(self):
        with patch.object(iot_admin.time, "monotonic", return_value=100):
            first = self.sessions.login(PASSWORD, "fixture-host")
            for _ in range(64):
                token = self.sessions.login(PASSWORD, "fixture-host")
            self.assertEqual(len(self.sessions.tokens), 64)
            self.assertNotIn(first, self.sessions.tokens)
            cookie = self.sessions.cookie(token, secure=True)
            parsed = SimpleCookie(cookie)["found_admin"]
            self.assertTrue(parsed["secure"])
            self.assertTrue(parsed["httponly"])
            self.assertEqual(parsed["samesite"], "Strict")
            self.assertTrue(self.sessions.authenticated(cookie))
        with patch.object(iot_admin.time, "monotonic", return_value=100 + iot_admin.SESSION_SECONDS):
            self.assertFalse(self.sessions.authenticated(cookie))

    def test_rate_limit_is_per_address_and_expires_after_five_minutes(self):
        with patch.object(iot_admin.time, "monotonic", return_value=100):
            for _ in range(10):
                with self.assertRaises(vision.VisionError) as error:
                    self.sessions.login("wrong", "blocked-host")
                self.assertEqual(error.exception.status, 401)
            with self.assertRaises(vision.VisionError) as error:
                self.sessions.login(PASSWORD, "blocked-host")
            self.assertEqual(error.exception.status, 429)
            self.assertTrue(self.sessions.login(PASSWORD, "other-host"))
        with patch.object(iot_admin.time, "monotonic", return_value=401):
            self.assertTrue(self.sessions.login(PASSWORD, "blocked-host"))
            self.assertNotIn("blocked-host", self.sessions.failures)

    def test_failed_address_history_is_bounded(self):
        with patch.object(iot_admin.time, "monotonic", return_value=100):
            for index in range(300):
                with self.assertRaises(vision.VisionError):
                    self.sessions.login("wrong", f"fixture-{index}")
        self.assertEqual(len(self.sessions.failures), 256)


class TelemetryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.environment = [patch.object(iot_admin.platform, "system", return_value="Darwin"),
                            patch.object(iot_admin, "read_text", return_value=""),
                            patch.object(iot_admin.shutil, "disk_usage", return_value=SimpleNamespace(total=1000, used=250)),
                            patch.object(iot_admin.os, "getloadavg", return_value=(0.1, 0.2, 0.3))]
        for context in self.environment:
            context.start()
        with patch.object(iot_admin.time, "monotonic", return_value=0):
            self.telemetry = iot_admin.Telemetry(self.directory.name)

    def tearDown(self):
        for context in reversed(self.environment):
            context.stop()
        self.directory.cleanup()

    def sample(self, at, counters):
        with patch.object(iot_admin.time, "monotonic", return_value=at), \
                patch.object(iot_admin, "linux_counters", return_value=counters):
            return self.telemetry.sample()

    def test_rates_require_two_real_samples_and_cached_requests_do_not_invent_history(self):
        first = self.sample(10, ((100, 40), (1000, 250), 42, 100, (100, 200)))
        self.assertIsNone(first[1]["cpu_percent"])
        self.assertIsNone(first[1]["network"]["rx_bytes_per_second"])
        self.assertEqual(first[1]["memory"]["percent"], 25)
        self.assertEqual(len(first[1]["history"]), 1)
        self.assertEqual(self.sample(11, (None, None, None, None, None)), first)
        device, metrics = self.sample(14, ((200, 60), (1000, 500), 43, 104, (300, 600)))
        self.assertEqual(metrics["cpu_percent"], 80)
        self.assertEqual(metrics["network"]["rx_bytes_per_second"], 50)
        self.assertEqual(metrics["network"]["tx_bytes_per_second"], 100)
        self.assertEqual(metrics["disk"]["percent"], 25)
        self.assertEqual(len(metrics["history"]), 2)
        self.assertEqual(device["service_uptime_seconds"], 14)

    def test_counter_reset_and_unsupported_measurements_return_null(self):
        self.sample(10, ((100, 40), (1000, 250), 42, 100, (100, 200)))
        _, reset = self.sample(14, ((50, 20), None, None, None, (50, 100)))
        self.assertIsNone(reset["cpu_percent"])
        self.assertIsNone(reset["network"]["rx_bytes_per_second"])
        self.assertEqual(reset["memory"], {"total_bytes": None, "used_bytes": None, "percent": None})
        _, unsupported = self.sample(18, (None, None, None, None, None))
        self.assertIsNone(unsupported["network"]["rx_bytes"])
        self.assertIsNone(unsupported["cpu_temperature_celsius"])

    def test_disk_probe_failure_and_zero_capacity_remain_unknown(self):
        unknown = {"total_bytes": None, "used_bytes": None, "percent": None}
        with patch.object(iot_admin.shutil, "disk_usage", side_effect=OSError("fixture unavailable")):
            device, metrics = self.sample(10, (None, None, None, None, None))
        self.assertEqual(metrics["disk"], unknown)
        self.assertEqual(device["service_uptime_seconds"], 10)
        with patch.object(iot_admin.shutil, "disk_usage", return_value=SimpleNamespace(total=0, used=0)):
            _, metrics = self.sample(14, (None, None, None, None, None))
        self.assertEqual(metrics["disk"], unknown)
        self.assertEqual(len(metrics["history"]), 2)

    def test_ip_addresses_refresh_every_thirty_seconds_and_clear_when_unavailable(self):
        counters = (None, None, None, None, None)
        with patch.object(iot_admin.platform, "system", return_value="Linux"), \
                patch.object(iot_admin.subprocess, "run", side_effect=[
                    SimpleNamespace(stdout="192.168.1.2 2001:0db8::1"),
                    SimpleNamespace(stdout="192.168.1.3"), OSError("fixture unavailable"),
                ]) as command:
            first, _ = self.sample(100, counters)
            self.assertEqual(first["ip_addresses"], ["192.168.1.2", "2001:db8::1"])
            self.sample(103, counters)
            before_refresh, _ = self.sample(127, counters)
            self.assertEqual(before_refresh["ip_addresses"], first["ip_addresses"])
            self.assertEqual(command.call_count, 1)
            updated, _ = self.sample(130, counters)
            self.assertEqual(updated["ip_addresses"], ["192.168.1.3"])
            self.assertEqual(command.call_count, 2)
            unavailable, _ = self.sample(160, counters)
            self.assertEqual(unavailable["ip_addresses"], [])
            self.assertEqual(command.call_count, 3)
            command.assert_called_with(["hostname", "-I"], capture_output=True, text=True, timeout=1, check=True)

    def test_cpu_bounds_and_history_window(self):
        self.sample(10, ((100, 40), None, None, None, None))
        _, metrics = self.sample(14, ((110, 100), None, None, None, None))
        self.assertEqual(metrics["cpu_percent"], 0)
        for index in range(121):
            _, metrics = self.sample(20 + index * 3, ((200 + index * 100, 100), None, None, None, None))
        self.assertEqual(metrics["cpu_percent"], 100)
        self.assertEqual(len(metrics["history"]), 120)

    def test_gpio_level_reader_is_read_only_and_disabled_without_hardware(self):
        with patch.object(iot_admin.subprocess, "run") as command:
            self.assertEqual(iot_admin.gpio_levels(False), {})
            command.assert_not_called()
            command.return_value = SimpleNamespace(stdout="17: op -- pd | lo // GPIO17 = output\n26: op -- pd | hi // GPIO26 = output\n")
            self.assertEqual(iot_admin.gpio_levels(True), {17: 0, 26: 1})
            self.assertEqual(command.call_args.args[0], ["pinctrl", "get", "5,13,17,26"])


if __name__ == "__main__":
    unittest.main()
