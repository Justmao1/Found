import base64
from concurrent.futures import ThreadPoolExecutor
import http.client
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
import uuid
import zlib

from test_speech import response as speech_response, wav


spec = importlib.util.spec_from_file_location("photo_server", Path(__file__).resolve().parents[1] / "server.py")
server_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server_module)

# A real 1x1 red JPEG, converted from png() once with macOS ImageIO.
JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAAaADAAQAAAABAAAAAQAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAAQABAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A+L6KKK/lM/38P//Z"
)


def png(width=1, height=1):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(b"\0\xff\0\0")) + chunk(b"IEND", b""))


class PhotoServerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.ai_env = patch.dict(os.environ, {"LOST_FOUND_AI_CONFIG": str(Path(self.directory.name) / "absent.json"),
                                             "DASHSCOPE_API_KEY": ""})
        self.ai_env.start()
        self.addCleanup(self.ai_env.stop)
        self.start_server()

    def start_server(self):
        self.server = server_module.build_server("127.0.0.1", 0, self.directory.name, auto_recognize=False)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)

    def tearDown(self):
        self.stop_server()
        self.directory.cleanup()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def payload(self, **updates):
        payload = {"image": base64.b64encode(png()).decode(), "mime_type": "image/png",
                   "request_id": str(uuid.uuid4()), "note": "红色钥匙扣"}
        payload.update(updates)
        return payload

    def post(self, payload, headers=None):
        request_headers = {"Content-Type": "application/json", "X-Requested-With": "lost-found-box"}
        request_headers.update(headers or {})
        status, _, raw = self.request("POST", "/api/items", json.dumps(payload).encode(), request_headers)
        return status, json.loads(raw)

    def test_upload_list_image_and_restart_persistence(self):
        status, created = self.post(self.payload())
        self.assertEqual(status, 201)
        self.assertFalse(created["duplicate"])
        item = created["item"]
        self.assertEqual(item["status"], "recorded")
        self.assertEqual(item["note"], "红色钥匙扣")
        self.assertTrue(item["created_at"].endswith("Z"))
        status, headers, body = self.request("GET", item["image_url"])
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "image/png")
        self.assertEqual(body, png())
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
        self.stop_server()
        self.start_server()
        status, _, raw = self.request("GET", "/api/items")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw), {"items": [item], "total": 1})

    def test_concurrent_idempotency_and_conflict(self):
        payload = self.payload()
        with ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda _: self.post(payload), range(6)))
        self.assertEqual(sorted(status for status, _ in results), [200] * 5 + [201])
        self.assertEqual(len({body["item"]["id"] for _, body in results}), 1)
        self.assertEqual(sum(body["duplicate"] for _, body in results), 5)
        status, _ = self.post(dict(payload, note="different"))
        self.assertEqual(status, 409)
        _, _, raw = self.request("GET", "/api/items")
        self.assertEqual(json.loads(raw)["total"], 1)

    def test_jpeg_upload_and_invalid_jpeg(self):
        status, result = self.post(self.payload(mime_type="image/jpeg", image=base64.b64encode(JPEG).decode()))
        self.assertEqual(status, 201)
        status, headers, raw = self.request("GET", result["item"]["image_url"])
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "image/jpeg")
        self.assertEqual(raw, JPEG)
        for image in (JPEG[:-2], b"\xff\xd8junk\xff\xd9", JPEG[:100] + b"\xff\xd9"):
            self.assertEqual(self.post(self.payload(mime_type="image/jpeg", image=base64.b64encode(image).decode()))[0], 400)

    def test_list_returns_latest_100_with_full_total(self):
        db = self.server.connect_db()
        try:
            with db:
                for index in range(101):
                    db.execute("INSERT INTO items VALUES (?, ?, ?, ?, ?, ?, ?)",
                               (str(uuid.uuid4()), str(uuid.uuid4()), "test", "2026-10-13T00:00:00.000Z",
                                str(index), "image/png", png()))
        finally:
            db.close()
        status, _, raw = self.request("GET", "/api/items")
        self.assertEqual(status, 200)
        result = json.loads(raw)
        self.assertEqual(result["total"], 101)
        self.assertEqual(len(result["items"]), 100)
        self.assertEqual(result["items"][0]["note"], "100")
        self.assertEqual(result["items"][-1]["note"], "1")

    def test_invalid_input_rejected_without_records(self):
        malformed = [None, [], "text", self.payload(note="x" * 201), self.payload(note=None),
                     self.payload(note="\ud800"), self.payload(request_id="bad"),
                     self.payload(request_id=3), self.payload(image="not-base64"),
                     self.payload(image="data:image/png;base64," + base64.b64encode(png()).decode()),
                     self.payload(mime_type="image/svg+xml"), self.payload(image=""),
                     self.payload(image=base64.b64encode(b"not an image").decode()),
                     self.payload(mime_type="image/jpeg"),
                     self.payload(image=base64.b64encode(png()[:-1]).decode()),
                     self.payload(image=base64.b64encode(png(12001)).decode()),
                     self.payload(image=base64.b64encode(png(0)).decode())]
        for payload in malformed:
            with self.subTest(payload=str(payload)[:100]):
                status, result = self.post(payload)
                self.assertEqual(status, 400)
                self.assertIn("error", result)
        headers = {"Content-Type": "application/json", "X-Requested-With": "lost-found-box"}
        for raw in (b"{", b"\xff", b"[" * 2000):
            status, _, body = self.request("POST", "/api/items", raw, headers)
            self.assertEqual(status, 400)
            self.assertIn("error", json.loads(body))
        _, _, raw = self.request("GET", "/api/items")
        self.assertEqual(json.loads(raw)["total"], 0)

    def test_body_and_image_size_limits(self):
        # Reject an oversized declared request before reading any of its body.
        headers = {"Content-Type": "application/json", "X-Requested-With": "lost-found-box",
                   "Content-Length": str(server_module.MAX_BODY_BYTES + 1)}
        status, _, _ = self.request("POST", "/api/items", b"", headers)
        self.assertEqual(status, 413)
        status, _ = self.post(self.payload(image=base64.b64encode(b"x" * (server_module.MAX_IMAGE_BYTES + 1)).decode()))
        self.assertEqual(status, 413)

    def test_origin_and_custom_header(self):
        for origin in ("https://evil.example", "null", "http://127.0.0.1:1", "http://[bad"):
            self.assertEqual(self.post(self.payload(), {"Origin": origin})[0], 403)
        self.assertEqual(self.post(self.payload(), {"X-Requested-With": ""})[0], 403)
        origin = "http://127.0.0.1:{}".format(self.server.server_port)
        self.assertEqual(self.post(self.payload(), {"Origin": origin})[0], 201)

    def test_routes_do_not_expose_files(self):
        for path in ("/server.py", "/data/items.sqlite3", "/certs/server-key.pem", "/../server.py",
                     "/%2e%2e/server.py", "/images/../data/items.sqlite3", "/images/" + str(uuid.uuid4()),
                     "/static/../server.py", "//[malformed"):
            self.assertEqual(self.request("GET", path)[0], 404, path)
        self.assertEqual(self.request("GET", "/api/health")[2], b'{"ok": true}')
        self.assertEqual(self.request("POST", "/missing")[0], 404)
        self.assertEqual(self.request("DELETE", "/api/items")[0], 501)

    def test_bad_length_and_content_type(self):
        headers = {"X-Requested-With": "lost-found-box", "Content-Type": "application/json"}
        for length in ("-1", "oops", ""):
            status, _, _ = self.request("POST", "/api/items", b"", dict(headers, **{"Content-Length": length}))
            self.assertEqual(status, 400)
        status, _, _ = self.request("POST", "/api/items", b"{}", dict(headers, **{"Transfer-Encoding": "chunked"}))
        self.assertEqual(status, 400)
        self.assertEqual(self.post(self.payload(), {"Content-Type": "text/plain"})[0], 415)

    def test_plaintext_network_binding_is_rejected(self):
        for host in ("0.0.0.0", "192.168.5.3", "work123.local"):
            with self.assertRaisesRegex(ValueError, "HTTPS"):
                server_module.build_server(host, 0, self.directory.name)
        with self.assertRaises(ValueError):
            server_module.build_server("127.0.0.1", 0, self.directory.name, cert="missing.pem")


class SpeechHTTPTests(unittest.TestCase):
    setUp = PhotoServerTests.setUp
    tearDown = PhotoServerTests.tearDown
    start_server = PhotoServerTests.start_server
    stop_server = PhotoServerTests.stop_server
    request = PhotoServerTests.request

    def post_speech(self, payload=None, headers=None):
        payload = payload if payload is not None else {"audio": base64.b64encode(wav()).decode(), "mime_type": "audio/wav"}
        request_headers = {"Content-Type": "application/json", "X-Requested-With": "lost-found-box"}
        request_headers.update(headers or {})
        status, _, raw = self.request("POST", "/api/transcribe", json.dumps(payload).encode(), request_headers)
        return status, json.loads(raw)

    def test_success_returns_only_text_and_never_writes_database_or_files(self):
        db = self.server.connect_db()
        try:
            before = list(db.iterdump())
            files_before = set(Path(self.directory.name).rglob("*"))
            with patch("speech.transcribe", return_value="a blue bottle") as transcribe:
                status, result = self.post_speech()
            self.assertEqual((status, result), (200, {"text": "a blue bottle"}))
            transcribe.assert_called_once_with(wav())
            self.assertEqual(list(db.iterdump()), before)
            self.assertEqual(set(Path(self.directory.name).rglob("*")), files_before)
        finally:
            db.close()

    def test_http_contract_rejects_invalid_payload_before_provider(self):
        malformed = [{}, [], "text", {"audio": "not base64", "mime_type": "audio/wav"},
                     {"audio": base64.b64encode(wav()[:-1]).decode(), "mime_type": "audio/wav"},
                     {"audio": base64.b64encode(wav()).decode(), "mime_type": "audio/m4a"}]
        with patch("speech.transcribe") as transcribe:
            for payload in malformed:
                self.assertEqual(self.post_speech(payload)[0], 400)
            self.assertEqual(self.post_speech(headers={"Content-Type": "text/plain"})[0], 415)
            self.assertEqual(self.post_speech(headers={"X-Requested-With": ""})[0], 403)
            for origin in ("https://evil.example", "null", "http://127.0.0.1:1"):
                self.assertEqual(self.post_speech(headers={"Origin": origin})[0], 403)
            transcribe.assert_not_called()

    def test_same_origin_native_requests_and_no_store_response(self):
        with patch("speech.transcribe", return_value="bottle"):
            origin = "http://127.0.0.1:" + str(self.server.server_port)
            self.assertEqual(self.post_speech(headers={"Origin": origin})[0], 200)
            status, headers, raw = self.request("POST", "/api/transcribe", json.dumps(
                {"audio": base64.b64encode(wav()).decode(), "mime_type": "audio/wav"}).encode(),
                {"Content-Type": "application/json", "X-Requested-With": "lost-found-box"})
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(json.loads(raw), {"text": "bottle"})

    def test_body_and_audio_limits_and_ambiguous_length_are_rejected(self):
        headers = {"Content-Type": "application/json", "X-Requested-With": "lost-found-box"}
        with patch("speech.transcribe") as transcribe:
            for length, expected in ((str(server_module.speech.MAX_BODY_BYTES + 1), 413),
                                     ("9" * 13, 413), ("-1", 400)):
                self.assertEqual(self.request("POST", "/api/transcribe", b"", dict(headers, **{"Content-Length": length}))[0], expected)
            self.assertEqual(self.request("POST", "/api/transcribe", b"", dict(headers, **{"Transfer-Encoding": "chunked"}))[0], 400)
            oversized = {"audio": base64.b64encode(b"x" * (server_module.speech.MAX_AUDIO_BYTES + 1)).decode(), "mime_type": "audio/wav"}
            self.assertEqual(self.post_speech(oversized)[0], 413)
            for body in (b"{", b"\xff", b"[" * 2000):
                self.assertEqual(self.request("POST", "/api/transcribe", body, headers)[0], 400)
            transcribe.assert_not_called()

    def test_missing_config_and_provider_failure_are_safe_and_release_slot(self):
        self.assertEqual(self.post_speech()[0], 503)
        opener = Mock()
        opener.open.side_effect = HTTPError("https://example.com", 401, "secret", {}, io.BytesIO(b"secret"))
        with patch.dict(os.environ, {"DASHSCOPE_API_KEY": "unit-test-secret"}), patch("speech.build_opener", return_value=opener):
            status, result = self.post_speech()
            self.assertEqual(status, 502)
            self.assertNotIn("secret", result["error"])
            opener.open.assert_called_once()
            opener.open.side_effect = None
            opener.open.return_value = io.BytesIO(json.dumps(speech_response("keys")).encode())
            self.assertEqual(self.post_speech(), (200, {"text": "keys"}))

    def test_concurrent_speech_is_rejected_and_does_not_use_search_slot(self):
        entered, release = threading.Event(), threading.Event()

        def transcribe(audio):
            entered.set()
            if not release.wait(timeout=3):
                raise RuntimeError("Test did not release the speech request")
            return "keys"

        self.assertTrue(self.server.search_slot.acquire(blocking=False))
        try:
            with patch("speech.transcribe", side_effect=transcribe) as provider, ThreadPoolExecutor(max_workers=2) as pool:
                first = pool.submit(self.post_speech)
                try:
                    self.assertTrue(entered.wait(timeout=2))
                    self.assertEqual(self.post_speech()[0], 503)
                finally:
                    release.set()
                self.assertEqual(first.result(timeout=3), (200, {"text": "keys"}))
                provider.assert_called_once()
            with patch("speech.transcribe", return_value="bottle"):
                self.assertEqual(self.post_speech(), (200, {"text": "bottle"}))
        finally:
            self.server.search_slot.release()


if __name__ == "__main__":
    unittest.main()
