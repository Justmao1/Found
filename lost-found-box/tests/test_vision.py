import base64
from concurrent.futures import ThreadPoolExecutor
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError
from urllib.request import Request
import uuid

import vision
import test_server as server_tests

png = server_tests.png
server_module = server_tests.server_module


FIELDS = {"tags": ["Keys", "Red", "Round keyring"]}
RECOGNITION = dict(FIELDS, model=vision.DEFAULT_MODEL, version=3)

def response_bytes(fields=FIELDS, finish="stop"):
    return json.dumps({"choices": [{"finish_reason": finish, "message": {
        "content": json.dumps(fields, ensure_ascii=False)}}]}).encode()


class VisionClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "ai.json"
        self.env = patch.dict(os.environ, {"LOST_FOUND_AI_CONFIG": str(self.path)}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.addCleanup(self.temp.cleanup)

    def configure(self, **updates):
        config = {"api_key": "unit-test-secret", "model": vision.DEFAULT_MODEL,
                  "base_url": vision.DEFAULT_BASE_URL}
        config.update(updates)
        self.path.write_text(json.dumps(config))

    def run_provider(self, body):
        opener = Mock()
        opener.open.return_value = io.BytesIO(body)
        with patch.object(vision, "build_opener", return_value=opener):
            result = vision.recognize(png(), "image/png")
        return result, opener

    def test_request_contains_saved_image_json_options_and_secret_only_in_header(self):
        self.configure()
        result, opener = self.run_provider(response_bytes())
        self.assertEqual(result, RECOGNITION)
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, vision.DEFAULT_BASE_URL + "/chat/completions")
        self.assertEqual(request.headers["Authorization"], "Bearer unit-test-secret")
        self.assertNotIn("unit-test-secret", request.data.decode())
        payload = json.loads(request.data)
        self.assertEqual(payload["response_format"], {"type": "json_object"})
        self.assertFalse(payload["enable_thinking"])
        self.assertEqual(payload["max_tokens"], 200)
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 30)
        content = payload["messages"][0]["content"]
        self.assertEqual(content[0]["image_url"]["url"], "data:image/png;base64," + base64.b64encode(png()).decode())
        self.assertIn("JSON", content[1]["text"])
        self.assertIn("not instructions", content[1]["text"])
        self.assertEqual(vision.configuration_status(), {"configured": True, "model": vision.DEFAULT_MODEL})

    def test_missing_invalid_config_and_host_allowlist(self):
        self.assertFalse(vision.configuration_status()["configured"])
        with self.assertRaises(vision.VisionError) as caught:
            vision.recognize(png(), "image/png")
        self.assertEqual(caught.exception.status, 503)
        for url in ("http://dashscope.aliyuncs.com/compatible-mode/v1",
                    "https://dashscope.aliyuncs.com.evil.test/compatible-mode/v1",
                    "https://user:pass@dashscope.aliyuncs.com/compatible-mode/v1",
                    "https://dashscope.aliyuncs.com:444/compatible-mode/v1",
                    "https://127.0.0.1/compatible-mode/v1",
                    "https://dashscope.aliyuncs.com/compatible-mode/v1?key=secret"):
            self.configure(base_url=url)
            self.assertFalse(vision.configuration_status()["configured"], url)
        self.configure(base_url="https://workspace-123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
        self.assertTrue(vision.configuration_status()["configured"])
        self.configure(api_key="bad\nheader")
        self.assertFalse(vision.configuration_status()["configured"])
        self.path.write_text("{")
        self.assertFalse(vision.configuration_status()["configured"])

    def test_provider_errors_redacted_and_no_automatic_retry(self):
        self.configure()
        for error, expected in ((HTTPError("https://example.test", 401, "unit-test-secret", {}, io.BytesIO(b"secret")), 502),
                                (URLError("unit-test-secret"), 502),
                                (TimeoutError("unit-test-secret"), 504),
                                (URLError(TimeoutError("unit-test-secret")), 504)):
            opener = Mock()
            opener.open.side_effect = error
            with patch.object(vision, "build_opener", return_value=opener):
                with self.assertRaises(vision.VisionError) as caught:
                    vision.recognize(png(), "image/png")
            self.assertEqual(caught.exception.status, expected)
            self.assertNotIn("secret", str(caught.exception))
            opener.open.assert_called_once()

    def test_malformed_truncated_and_unbounded_results_rejected(self):
        self.configure()
        invalid = [b"not json", b"{}", b"null", b"x" * (vision.MAX_RESPONSE_BYTES + 1),
                   response_bytes(finish="length"), response_bytes([]), response_bytes({"tags": []}),
                   response_bytes({"tags": ["x" * 25]}), response_bytes({"tags": ["x"] * 6}),
                   response_bytes({"tags": [None]}), response_bytes(dict(FIELDS, extra="bad")),
                   response_bytes({"tags": ["重复", "重复"]}), response_bytes({"tags": [" "]}),
                   response_bytes({"tags": ["\ud800"]})]
        for body in invalid:
            with self.subTest(body=body[:50]):
                with self.assertRaises(vision.VisionError) as caught:
                    self.run_provider(body)
                self.assertEqual(caught.exception.status, 502)

    def test_redirect_does_not_forward_request(self):
        request = Request("https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
                          headers={"Authorization": "Bearer unit-test-secret"})
        self.assertIsNone(vision.NoRedirect().redirect_request(request, None, 302, "", {}, "https://evil.test"))


class RecognitionHTTPTests(unittest.TestCase):
    start_server = server_tests.PhotoServerTests.start_server
    stop_server = server_tests.PhotoServerTests.stop_server
    request = server_tests.PhotoServerTests.request
    payload = server_tests.PhotoServerTests.payload
    post = server_tests.PhotoServerTests.post

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"LOST_FOUND_AI_CONFIG": str(Path(self.directory.name) / "absent.json")}, clear=True)
        self.env.start()
        Path(os.environ["LOST_FOUND_AI_CONFIG"]).write_text(json.dumps({"api_key": "unit-test-only"}))
        self.start_server()
        self.upload_payload = self.payload()
        self.item = self.post(self.upload_payload)[1]["item"]

    def tearDown(self):
        self.stop_server()
        self.env.stop()
        self.directory.cleanup()

    def recognize(self, identifier=None, headers=None, payload=None):
        base = {"Content-Type": "application/json", "X-Requested-With": "lost-found-box"}
        base.update(headers or {})
        status, _, raw = self.request("POST", "/api/items/" + (identifier or self.item["id"]) + "/recognize",
                                      json.dumps(payload or {}), base)
        return status, json.loads(raw)

    def test_persist_cache_list_create_and_restart(self):
        self.assertIsNone(self.item["recognition"])
        with patch.object(server_module.vision, "recognize", return_value=RECOGNITION) as provider:
            status, body = self.recognize()
            self.assertEqual(status, 200)
            self.assertEqual(body["item"]["recognition"], RECOGNITION)
            self.assertEqual(self.recognize(), (200, body))
            provider.assert_called_once_with(png(), "image/png")
            self.assertEqual(self.post(self.upload_payload)[1]["item"], body["item"])
            self.stop_server()
            self.start_server()
            self.assertEqual(self.recognize(), (200, body))
            provider.assert_called_once()
        self.assertEqual(json.loads(self.request("GET", "/api/items")[2])["items"], [body["item"]])
        self.assertEqual(self.request("GET", self.item["image_url"])[2], png())

    def test_same_item_concurrent_requests_share_one_call(self):
        entered, release = threading.Event(), threading.Event()
        def provider(image, mime):
            entered.set()
            self.assertTrue(release.wait(3))
            return RECOGNITION
        with patch.object(server_module.vision, "recognize", side_effect=provider) as mocked:
            with ThreadPoolExecutor(max_workers=6) as pool:
                futures = [pool.submit(self.recognize) for _ in range(6)]
                self.assertTrue(entered.wait(2))
                release.set()
                results = [future.result() for future in futures]
        self.assertTrue(all(status == 200 for status, _ in results))
        self.assertEqual(mocked.call_count, 1)
        self.assertEqual(self.server.ai_pending, {})

    def test_parallel_cloud_calls_serialized(self):
        ids = [self.item["id"], self.post(self.payload())[1]["item"]["id"]]
        entered, release = threading.Event(), threading.Event()
        def provider(image, mime):
            entered.set()
            self.assertTrue(release.wait(3))
            return RECOGNITION
        with patch.object(server_module.vision, "recognize", side_effect=provider) as mocked:
            first = self.server.enqueue_recognition(ids[0])
            self.assertTrue(entered.wait(2))
            second = self.server.enqueue_recognition(ids[1])
            self.assertEqual(mocked.call_count, 1)
            self.assertFalse(second.done())
            release.set()
            self.assertEqual(first.result(3)["recognition"], RECOGNITION)
            self.assertEqual(second.result(3)["recognition"], RECOGNITION)
        self.assertEqual(mocked.call_count, 2)

    def test_failures_leave_photo_and_allow_manual_retry(self):
        Path(os.environ["LOST_FOUND_AI_CONFIG"]).unlink()
        self.assertEqual(self.recognize()[0], 503)
        status = json.loads(self.request("GET", "/api/ai/status")[2])
        self.assertEqual(status, {"configured": False, "model": vision.DEFAULT_MODEL})
        Path(os.environ["LOST_FOUND_AI_CONFIG"]).write_text(json.dumps({"api_key": "unit-test-only"}))
        for code in (502, 504):
            with patch.object(server_module.vision, "recognize", side_effect=vision.VisionError(code, "安全错误")):
                self.assertEqual(self.recognize()[0], code)
            self.assertEqual(self.request("GET", self.item["image_url"])[2], png())
            self.assertIsNone(json.loads(self.request("GET", "/api/items")[2])["items"][0]["recognition"])
        with patch.object(server_module.vision, "recognize", return_value=RECOGNITION):
            self.assertEqual(self.recognize()[0], 200)

    def test_source_validation_and_missing_items(self):
        with patch.object(server_module.vision, "recognize") as provider:
            self.assertEqual(self.recognize(headers={"Origin": "https://evil.test"})[0], 403)
            self.assertEqual(self.recognize(headers={"X-Requested-With": ""})[0], 403)
            self.assertEqual(self.recognize(str(uuid.uuid4()))[0], 404)
            self.assertEqual(self.recognize("not-a-uuid")[0], 404)
            self.assertEqual(self.recognize(payload={"image": "injected"})[0], 400)
            provider.assert_not_called()


class AutomaticRecognitionTests(unittest.TestCase):
    setUp = RecognitionHTTPTests.setUp
    tearDown = RecognitionHTTPTests.tearDown
    start_server = RecognitionHTTPTests.start_server
    stop_server = RecognitionHTTPTests.stop_server
    request = RecognitionHTTPTests.request
    payload = RecognitionHTTPTests.payload
    post = RecognitionHTTPTests.post
    recognize = RecognitionHTTPTests.recognize
    def test_save_returns_while_provider_waits_and_duplicate_does_not_repeat(self):
        self.server.auto_recognize = True
        entered, release = threading.Event(), threading.Event()
        def provider(image, mime):
            entered.set()
            self.assertTrue(release.wait(3))
            return RECOGNITION
        payload = self.payload()
        with patch.object(vision, "recognize", side_effect=provider) as mocked:
            try:
                status, response = self.post(payload)
                self.assertEqual(status, 201)
                self.assertTrue(entered.wait(2))
                self.assertIn(response["item"]["recognition_status"], ("pending", "processing"))
                self.assertIsNone(response["item"]["recognition"])
                duplicate = self.post(payload)
                self.assertEqual(duplicate[0], 200)
                future = self.server.ai_pending[response["item"]["id"]]
            finally:
                release.set()
            self.assertEqual(future.result(3)["recognition_status"], "complete")
            self.assertEqual(self.post(payload)[1]["item"]["recognition"], RECOGNITION)
            mocked.assert_called_once()

    def test_auto_queue_is_bounded_and_surplus_photo_survives(self):
        entered, release = threading.Event(), threading.Event()
        def provider(image, mime):
            entered.set()
            self.assertTrue(release.wait(5))
            return RECOGNITION
        with patch.object(vision, "recognize", side_effect=provider):
            self.server.enqueue_recognition(self.item["id"])
            self.assertTrue(entered.wait(2))
            try:
                db = self.server.connect_db()
                with db:
                    for index in range(65):
                        identifier = str(uuid.uuid4())
                        db.execute("INSERT INTO items VALUES (?, ?, ?, ?, ?, ?, ?)",
                                   (identifier, str(uuid.uuid4()), "test", "2026-10-14T00:00:00Z", "", "image/png", png()))
                        # Commit before queue lookup uses its independent connection.
                        db.commit()
                        if index < 64:
                            self.server.enqueue_recognition(identifier)
                        else:
                            with self.assertRaises(vision.VisionError) as caught:
                                self.server.enqueue_recognition(identifier)
                            self.assertEqual(caught.exception.status, 503)
                            self.assertEqual(self.request("GET", "/images/" + identifier)[2], png())
                db.close()
                self.assertEqual(self.server.ai_queue.qsize(), 64)
            finally:
                release.set()
            self.server.ai_queue.join()

    def test_failed_auto_not_retried_by_reads_duplicate_or_restart(self):
        self.server.auto_recognize = True
        with patch.object(vision, "recognize", side_effect=vision.VisionError(502, "failed")) as mocked:
            payload = self.payload()
            item = self.post(payload)[1]["item"]
            self.server.ai_queue.join()
            for _ in range(3):
                self.request("GET", "/api/items")
                self.post(payload)
            self.assertEqual(mocked.call_count, 1)
            self.stop_server()
            self.start_auto_server()
            self.server.ai_queue.join()
            # The setup item was previously unrecognized, so startup processes it once.
            self.assertEqual(mocked.call_count, 2)
            self.assertEqual(self.request("GET", item["image_url"])[2], png())
        with patch.object(vision, "recognize", return_value=RECOGNITION) as mocked:
            self.assertEqual(self.recognize(item["id"])[0], 200)
            mocked.assert_called_once()

    def start_auto_server(self):
        self.server = server_module.build_server("127.0.0.1", 0, self.directory.name, auto_recognize=True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def test_startup_refreshes_legacy_hides_long_text_and_keeps_v2(self):
        second = self.post(self.payload())[1]["item"]
        db = self.server.connect_db()
        with db:
            db.execute("INSERT INTO recognitions VALUES (?, ?)", (self.item["id"], json.dumps({"name": "legacy long text"})))
            db.execute("INSERT INTO recognitions VALUES (?, ?)", (second["id"], json.dumps(RECOGNITION)))
        db.close()
        items = json.loads(self.request("GET", "/api/items")[2])["items"]
        self.assertIsNone(next(item for item in items if item["id"] == self.item["id"])["recognition"])
        self.stop_server()
        with patch.object(vision, "recognize", return_value=RECOGNITION) as mocked:
            self.start_auto_server()
            self.server.ai_queue.join()
            mocked.assert_called_once()
        items = json.loads(self.request("GET", "/api/items")[2])["items"]
        self.assertTrue(all(item["recognition_status"] == "complete" for item in items))
        self.assertEqual(len(items), 2)
        self.stop_server()
        self.assertFalse(self.server.ai_worker.is_alive())
        self.start_server()


if __name__ == "__main__":
    unittest.main()
