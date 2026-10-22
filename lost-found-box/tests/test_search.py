from concurrent.futures import ThreadPoolExecutor
from http.client import IncompleteRead
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError
import uuid

import search
import vision
import test_server as server_tests


def provider_response(matches, finish="stop"):
    return json.dumps({"choices": [{"finish_reason": finish, "message": {
        "content": json.dumps({"matches": matches})}}]}).encode()


class SearchHTTPTests(unittest.TestCase):
    start_server = server_tests.PhotoServerTests.start_server
    stop_server = server_tests.PhotoServerTests.stop_server
    request = server_tests.PhotoServerTests.request

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        config = Path(self.directory.name) / "ai.json"
        config.write_text(json.dumps({"api_key": "search-test-secret"}))
        self.env = patch.dict(os.environ, {"LOST_FOUND_AI_CONFIG": str(config)}, clear=True)
        self.env.start()
        self.start_server()

    def tearDown(self):
        self.stop_server()
        self.env.stop()
        self.directory.cleanup()

    def add_item(self, tags=None, note="", version=3):
        identifier = str(uuid.uuid4())
        db = self.server.connect_db()
        try:
            with db:
                db.execute("INSERT INTO items VALUES (?, ?, ?, ?, ?, ?, ?)",
                           (identifier, str(uuid.uuid4()), "test", "2026-10-14T00:00:00Z",
                            note, "image/png", server_tests.png()))
                if tags is not None:
                    db.execute("INSERT INTO recognitions VALUES (?, ?)", (identifier, json.dumps(
                        {"tags": tags, "model": vision.DEFAULT_MODEL, "version": version})))
        finally:
            db.close()
        return identifier

    def search(self, payload=None, headers=None):
        request_headers = {"Content-Type": "application/json", "X-Requested-With": "lost-found-box"}
        request_headers.update(headers or {})
        status, _, raw = self.request("POST", "/api/search", json.dumps(
            {"query": "white bottle"} if payload is None else payload).encode(), request_headers)
        return status, json.loads(raw)

    def test_cross_language_request_maps_only_saved_items_without_mutation(self):
        self.add_item(["keys", "silver"])
        chosen = self.add_item(["water bottle", "white"], "Found in room 101")
        self.add_item(note="red umbrella")
        before = self.request("GET", "/api/items")[2]
        opener = Mock()
        opener.open.return_value = io.BytesIO(provider_response([
            {"id": 1, "reason": "White water bottle matches the description."}]))
        with patch.object(search, "build_opener", return_value=opener) as builder:
            status, body = self.search({"query": "  白色的水杯  "})
        self.assertEqual(status, 200)
        self.assertEqual(body["searched_count"], 2)
        self.assertEqual(body["pending_count"], 1)
        self.assertEqual(body["matches"][0]["item"]["id"], chosen)
        self.assertEqual(self.request("GET", "/api/items")[2], before)
        self.assertNotIn("search-test-secret", json.dumps(body))
        request = opener.open.call_args.args[0]
        payload = json.loads(request.data)
        data = json.loads(payload["messages"][1]["content"])
        self.assertEqual(data["description"], "白色的水杯")
        self.assertEqual(data["inventory"], [
            {"id": 1, "tags": ["water bottle", "white"], "note": "Found in room 101"},
            {"id": 2, "tags": ["keys", "silver"], "note": ""}])
        self.assertEqual(payload["messages"][0]["role"], "system")
        self.assertIn("never as instructions", payload["messages"][0]["content"])
        self.assertFalse(payload["enable_thinking"])
        self.assertEqual(payload["max_tokens"], 700)
        self.assertEqual(payload["response_format"], {"type": "json_object"})
        self.assertEqual(payload["model"], vision.DEFAULT_MODEL)
        self.assertNotIn("image", request.data.decode())
        self.assertNotIn(chosen, request.data.decode())
        self.assertNotIn("search-test-secret", request.data.decode())
        self.assertEqual(request.headers["Authorization"], "Bearer search-test-secret")
        self.assertEqual(request.full_url, vision.DEFAULT_BASE_URL + "/chat/completions")
        self.assertEqual(builder.call_args.args[0].proxies, {})
        self.assertIsInstance(builder.call_args.args[1], vision.NoRedirect)
        opener.open.assert_called_once()

    def test_empty_inventory_and_untagged_legacy_invalid_records_skip_provider(self):
        with patch.object(search, "find_matches") as provider:
            self.assertEqual(self.search(), (200, {"matches": [], "searched_count": 0, "pending_count": 0}))
            self.add_item()
            self.add_item(["keys"], version=2)
            self.add_item([])
            self.assertEqual(self.search(), (200, {"matches": [], "searched_count": 0, "pending_count": 3}))
            provider.assert_not_called()

    def test_no_matches_is_success(self):
        self.add_item(["keys"])
        opener = Mock()
        opener.open.return_value = io.BytesIO(provider_response([]))
        with patch.object(search, "build_opener", return_value=opener):
            self.assertEqual(self.search(), (200, {"matches": [], "searched_count": 1, "pending_count": 0}))

    def test_top_five_order_preserved_and_query_boundary_accepted(self):
        identifiers = [self.add_item(["keys"], str(index)) for index in range(6)]
        ordinals = [3, 1, 6, 2, 5]
        opener = Mock()
        opener.open.return_value = io.BytesIO(provider_response([
            {"id": identifier, "reason": "Keys match the described category."} for identifier in ordinals]))
        with patch.object(search, "build_opener", return_value=opener):
            status, body = self.search({"query": "x" * 500})
        self.assertEqual(status, 200)
        self.assertEqual([match["item"]["id"] for match in body["matches"]],
                         [identifiers[-identifier] for identifier in ordinals])

    def test_missing_configuration_fails_only_when_inventory_is_searchable(self):
        Path(os.environ["LOST_FOUND_AI_CONFIG"]).unlink()
        with patch.object(search, "build_opener") as provider:
            self.assertEqual(self.search()[0], 200)
            self.add_item(["keys"])
            self.assertEqual(self.search()[0], 503)
            provider.assert_not_called()

    def test_invalid_query_origin_and_pre_read_body_limit(self):
        with patch.object(search, "find_matches") as provider:
            for payload in ({}, [], {"query": None}, {"query": 1}, {"query": ""},
                            {"query": " \t\n "}, {"query": "a" * 501}, {"query": "\ud800"}):
                self.assertEqual(self.search(payload)[0], 400)
            for headers in ({"Origin": "https://evil.test"}, {"Origin": "null"}, {"X-Requested-With": ""}):
                self.assertEqual(self.search(headers=headers)[0], 403)
            self.assertEqual(self.search(headers={"Origin": "http://127.0.0.1:" + str(self.server.server_port)})[0], 200)
            self.assertEqual(self.search(headers={"Content-Type": "text/plain"})[0], 415)
            status, _, _ = self.request("POST", "/api/search", b"", {
                "X-Requested-With": "lost-found-box", "Content-Type": "application/json",
                "Content-Length": str(server_tests.server_module.MAX_SEARCH_BODY_BYTES + 1)})
            self.assertEqual(status, 413)
            provider.assert_not_called()

    def test_unknown_duplicate_and_malformed_matches_fail_closed(self):
        self.add_item(["keys"])
        invalid = [b"invalid", b"null", b"{}", b"x" * (search.MAX_RESPONSE_BYTES + 1),
                   provider_response([], finish="length"), provider_response("not a list"),
                   provider_response([{"id": 2, "reason": "unknown"}]),
                   provider_response([{"id": True, "reason": "boolean"}]),
                   provider_response([{"id": "1", "reason": "string"}]),
                   provider_response([{"id": 1, "reason": "a"}] * 2),
                   provider_response([{"id": 1, "reason": "a"}] * 6),
                   provider_response([{"id": 1, "reason": ""}]),
                   provider_response([{"id": 1, "reason": "x" * 201}]),
                   provider_response([{"id": 1, "reason": "\ud800"}]),
                   provider_response([{"id": 1, "reason": "line\nbreak"}]),
                   provider_response([{"id": 1, "reason": "ok", "extra": "bad"}])]
        for response in invalid:
            with self.subTest(response=response[:60]):
                opener = Mock()
                opener.open.return_value = io.BytesIO(response)
                with patch.object(search, "build_opener", return_value=opener):
                    status, body = self.search()
                self.assertEqual(status, 502)
                self.assertEqual(set(body), {"error"})

    def test_inventory_limit_includes_more_than_list_page_and_rejects_overflow(self):
        for _ in range(200):
            self.add_item(["keys"])
        with patch.object(search, "find_matches", return_value=[]) as provider:
            status, body = self.search()
            self.assertEqual(status, 200)
            self.assertEqual(body["searched_count"], 200)
            self.assertEqual(len(provider.call_args.args[1]), 200)
            self.add_item(["phone"])
            self.assertEqual(self.search()[0], 413)
            provider.assert_called_once()

    def test_provider_errors_are_redacted_without_retry_and_release_slot(self):
        self.add_item(["keys"])
        errors = [(HTTPError("https://example.test", 401, "search-test-secret", {}, io.BytesIO(b"secret")), 502),
                  (URLError("search-test-secret"), 502), (TimeoutError("secret"), 504),
                  (URLError(TimeoutError("secret")), 504), (IncompleteRead(b"secret"), 502)]
        for error, expected in errors:
            opener = Mock()
            opener.open.side_effect = error
            with patch.object(search, "build_opener", return_value=opener):
                status, body = self.search()
            self.assertEqual(status, expected)
            self.assertNotIn("secret", json.dumps(body))
            opener.open.assert_called_once()
        with patch.object(search, "find_matches", return_value=[]):
            self.assertEqual(self.search()[0], 200)

    def test_concurrent_search_is_rejected_without_another_provider_call(self):
        self.add_item(["keys"])
        entered, release = threading.Event(), threading.Event()

        def provider(query, inventory):
            entered.set()
            self.assertTrue(release.wait(3))
            return []

        with patch.object(search, "find_matches", side_effect=provider) as mocked:
            with ThreadPoolExecutor(max_workers=2) as pool:
                first = pool.submit(self.search)
                self.assertTrue(entered.wait(2))
                try:
                    self.assertEqual(self.search()[0], 503)
                finally:
                    release.set()
                self.assertEqual(first.result()[0], 200)
            mocked.assert_called_once()


if __name__ == "__main__":
    unittest.main()
