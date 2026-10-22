#!/usr/bin/env python3
"""Photo registration for a trusted classroom demo; Python standard library only."""

import argparse
import base64
import binascii
from concurrent.futures import Future, TimeoutError as FutureTimeout
import hashlib
import ipaddress
import json
import logging
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import queue
import sqlite3
import ssl
import struct
import threading
from urllib.parse import parse_qs, urlsplit
import uuid
import zlib

import vision
import search
import speech
import lockers
import iot_admin


MAX_BODY_BYTES = 8 * 1024 * 1024
MAX_IMAGE_BYTES = 5 * 1024 * 1024
MAX_SEARCH_BODY_BYTES = 16 * 1024
STATIC_DIR = Path(__file__).resolve().parent / "static"


class InvalidImage(ValueError):
    pass


def validate_image(data, mime_type):
    """Validate container structure and dimensions, not fully decode image pixels."""
    if mime_type == "image/png":
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise InvalidImage()
        offset, width, height, seen_data, finished = 8, 0, 0, False, False
        while offset + 12 <= len(data):
            length = struct.unpack_from(">I", data, offset)[0]
            kind = data[offset + 4:offset + 8]
            end = offset + 12 + length
            if end > len(data):
                raise InvalidImage()
            content = data[offset + 8:end - 4]
            checksum = struct.unpack_from(">I", data, end - 4)[0]
            if zlib.crc32(kind + content) & 0xFFFFFFFF != checksum:
                raise InvalidImage()
            if offset == 8 and kind != b"IHDR":
                raise InvalidImage()
            if kind == b"IHDR":
                if offset != 8 or length != 13:
                    raise InvalidImage()
                width, height, depth, color, compression, filtering, interlace = struct.unpack(
                    ">IIBBBBB", content
                )
                depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8),
                          4: (8, 16), 6: (8, 16)}
                if depth not in depths.get(color, ()) or compression or filtering or interlace > 1:
                    raise InvalidImage()
            elif kind == b"IDAT":
                seen_data = seen_data or length > 0
            elif kind == b"IEND":
                if length or end != len(data) or not seen_data:
                    raise InvalidImage()
                finished = True
                break
            offset = end
        if not finished:
            raise InvalidImage()
    elif mime_type == "image/jpeg":
        if not data.startswith(b"\xff\xd8") or not data.endswith(b"\xff\xd9"):
            raise InvalidImage()
        offset, width, height, seen_scan = 2, 0, 0, False
        sof_markers = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                       0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
        while offset < len(data) - 2:
            if data[offset] != 0xFF:
                raise InvalidImage()
            while offset < len(data) and data[offset] == 0xFF:
                offset += 1
            if offset >= len(data):
                raise InvalidImage()
            marker = data[offset]
            offset += 1
            if offset + 2 > len(data) or marker in (0x00, 0xD8, 0xD9):
                raise InvalidImage()
            length = struct.unpack_from(">H", data, offset)[0]
            if length < 2 or offset + length > len(data) - 2:
                raise InvalidImage()
            if marker in sof_markers:
                if length < 8:
                    raise InvalidImage()
                height, width = struct.unpack_from(">HH", data, offset + 3)
                components = data[offset + 7]
                if components == 0 or length != 8 + 3 * components:
                    raise InvalidImage()
            if marker == 0xDA:
                if not width or length < 6 or offset + length >= len(data) - 2:
                    raise InvalidImage()
                seen_scan = True
                break
            offset += length
        if not seen_scan:
            raise InvalidImage()
    else:
        raise InvalidImage()
    if not 0 < width <= 12000 or not 0 < height <= 12000 or width * height > 24000000:
        raise InvalidImage()


def item_json(row):
    recognition = vision.cached_recognition(row["recognition"]) if "recognition" in row.keys() else None
    state = row["recognition_state"] if "recognition_state" in row.keys() else None
    if recognition:
        state = "complete"
    elif not state or state == "complete":
        state = "disabled" if not vision.configuration_status()["configured"] else "failed"
    return {"id": row["id"], "created_at": row["created_at"], "note": row["note"],
            "image_url": "/images/" + row["id"],
            "status": (row["storage_status"] or "recorded") if "storage_status" in row.keys() else "recorded",
            "compartment_id": row["compartment_id"] if "compartment_id" in row.keys() else None,
            "recognition": recognition, "recognition_status": state}


class PhotoServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, data_dir, auto_recognize=True, locker_driver=None):
        directory = Path(data_dir)
        directory.mkdir(parents=True, exist_ok=True)
        self.db_path = directory / "items.sqlite3"
        self.auto_recognize = auto_recognize
        self.ai_lock = threading.Lock()
        self.search_slot = threading.BoundedSemaphore(1)
        self.speech_slot = threading.BoundedSemaphore(1)
        self.ai_pending = {}
        self.ai_queue = queue.Queue(maxsize=64)
        self.ai_stopping = threading.Event()
        db = self.connect_db()
        try:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("""CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY, request_id TEXT NOT NULL UNIQUE,
                fingerprint TEXT NOT NULL, created_at TEXT NOT NULL,
                note TEXT NOT NULL, mime_type TEXT NOT NULL, image BLOB NOT NULL
            )""")
            db.execute("""CREATE TABLE IF NOT EXISTS recognitions (
                item_id TEXT PRIMARY KEY REFERENCES items(id), result TEXT NOT NULL
            )""")
            db.execute("""CREATE TABLE IF NOT EXISTS recognition_jobs (
                item_id TEXT PRIMARY KEY REFERENCES items(id), state TEXT NOT NULL
            )""")
            # A previous process may have stopped with work in flight. Rebuild only
            # the bounded startup queue; leave anything beyond it visibly retryable.
            db.execute("DELETE FROM recognition_jobs WHERE state IN ('pending', 'processing')")
            db.commit()
        finally:
            db.close()
        self.lockers = lockers.LockerStore(self.connect_db, directory, locker_driver)
        self.admin = iot_admin.Administration(self, item_json)
        super().__init__(address, PhotoHandler)
        self.ai_worker = threading.Thread(target=self._recognition_worker, daemon=True,
                                          name="lost-found-recognition")
        self.ai_worker.start()
        if auto_recognize and vision.configuration_status()["configured"]:
            db = self.connect_db()
            try:
                rows = db.execute("""SELECT items.id, recognitions.result AS recognition,
                    recognition_jobs.state AS recognition_state FROM items
                    LEFT JOIN recognitions ON recognitions.item_id = items.id
                    LEFT JOIN recognition_jobs ON recognition_jobs.item_id = items.id
                    WHERE recognition_jobs.state IS NULL OR recognition_jobs.state != 'failed'
                    ORDER BY items.created_at DESC, items.rowid DESC LIMIT 100""").fetchall()
            finally:
                db.close()
            for row in rows:
                if vision.cached_recognition(row["recognition"]) is None:
                    try:
                        self.enqueue_recognition(row["id"])
                    except vision.VisionError:
                        break

    def connect_db(self):
        db = sqlite3.connect(self.db_path, timeout=15)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        return db

    def fetch_item(self, db, identifier):
        return db.execute("""SELECT items.*, recognitions.result AS recognition,
            item_storage.status AS storage_status, item_storage.compartment_id,
            recognition_jobs.state AS recognition_state FROM items
            LEFT JOIN recognitions ON recognitions.item_id = items.id
            LEFT JOIN recognition_jobs ON recognition_jobs.item_id = items.id
            LEFT JOIN item_storage ON item_storage.item_id = items.id
            WHERE items.id = ?""", (identifier,)).fetchone()

    def operation_response(self, operation):
        db = self.connect_db()
        try:
            db.execute("BEGIN")
            current = db.execute("SELECT * FROM locker_operations WHERE id=?", (operation["id"],)).fetchone()
            return {"operation": lockers.operation_json(current),
                    "item": item_json(self.fetch_item(db, current["item_id"]))}
        finally:
            db.close()

    def search_items(self, query):
        if not self.search_slot.acquire(blocking=False):
            raise vision.VisionError(503, "Another search is in progress. Please try again shortly.")
        try:
            inventory, items, pending_count = [], [], 0
            db = self.connect_db()
            try:
                rows = db.execute("""SELECT items.id, created_at, note,
                    item_storage.status AS storage_status,item_storage.compartment_id,
                    recognitions.result AS recognition FROM items
                    LEFT JOIN recognitions ON recognitions.item_id = items.id
                    LEFT JOIN item_storage ON item_storage.item_id = items.id
                    LEFT JOIN compartments ON compartments.id = item_storage.compartment_id
                    WHERE (? = 0 AND item_storage.item_id IS NULL) OR (item_storage.status='stored' AND compartments.state='occupied'
                        AND compartments.item_id=items.id)
                    ORDER BY created_at DESC, items.rowid DESC""", (int(self.lockers.enabled),))
                for row in rows:
                    recognition = vision.cached_recognition(row["recognition"])
                    if recognition is None:
                        pending_count += 1
                        continue
                    if len(items) == search.MAX_INVENTORY:
                        raise vision.VisionError(413, "AI search supports up to 200 tagged items. The inventory is too large.")
                    items.append(item_json(row))
                    inventory.append({"id": len(items), "tags": recognition["tags"], "note": row["note"]})
            finally:
                db.close()
            matches = search.find_matches(query, inventory) if inventory else []
            candidates = [{"item": items[match["id"] - 1], "reason": match["reason"]} for match in matches]
            if candidates:
                # Cloud search may take seconds; an item can be collected meanwhile.
                db = self.connect_db()
                try:
                    db.execute("BEGIN")
                    current = []
                    for candidate in candidates:
                        row = self.fetch_item(db, candidate["item"]["id"])
                        legacy = row is not None and row["storage_status"] is None and not self.lockers.enabled
                        stored = row is not None and row["storage_status"] == "stored" and db.execute(
                            "SELECT 1 FROM compartments WHERE id=? AND item_id=? AND state='occupied'",
                            (row["compartment_id"], row["id"])).fetchone()
                        if legacy or stored:
                            current.append({"item": item_json(row), "reason": candidate["reason"]})
                    candidates = current
                finally:
                    db.close()
            return {"matches": candidates,
                    "searched_count": len(items), "pending_count": pending_count}
        finally:
            self.search_slot.release()

    def transcribe_audio(self, audio):
        if not self.speech_slot.acquire(blocking=False):
            raise vision.VisionError(503, "Another speech request is in progress. Please try again shortly.")
        try:
            return speech.transcribe(audio)
        finally:
            self.speech_slot.release()

    def _set_state(self, db, identifier, state):
        with db:
            db.execute("INSERT INTO recognition_jobs(item_id, state) VALUES (?, ?) "
                       "ON CONFLICT(item_id) DO UPDATE SET state=excluded.state", (identifier, state))

    def enqueue_recognition(self, identifier, automatic=False):
        with self.ai_lock:
            if identifier in self.ai_pending:
                return self.ai_pending[identifier]
            db = self.connect_db()
            try:
                row = self.fetch_item(db, identifier)
                if row is None:
                    raise vision.VisionError(404, "Item not found")
                future = Future()
                if vision.cached_recognition(row["recognition"]):
                    future.set_result(item_json(row))
                    return future
                if automatic and row["recognition_state"] == "failed":
                    return None
                if not vision.configuration_status()["configured"]:
                    self._set_state(db, identifier, "disabled")
                    raise vision.VisionError(503, "AI is not configured. Your photo is saved.")
                if self.ai_stopping.is_set() or self.ai_queue.full():
                    raise vision.VisionError(503, "AI is busy with other photos. Please retry later.")
                self._set_state(db, identifier, "pending")
                self.ai_pending[identifier] = future
                self.ai_queue.put_nowait((identifier, future))
                return future
            finally:
                db.close()

    def recognize_item(self, identifier):
        future = self.enqueue_recognition(identifier)
        try:
            return future.result(timeout=35)
        except FutureTimeout:
            raise vision.VisionError(504, "Tagging is queued or in progress. Your photo is saved; check back shortly.") from None

    def _recognition_worker(self):
        while not self.ai_stopping.is_set():
            try:
                identifier, future = self.ai_queue.get(timeout=0.2)
            except queue.Empty:
                continue
            db = self.connect_db()
            try:
                self._set_state(db, identifier, "processing")
                row = self.fetch_item(db, identifier)
                result = vision.recognize(row["image"], row["mime_type"])
                with db:
                    db.execute("INSERT INTO recognitions(item_id, result) VALUES (?, ?) "
                               "ON CONFLICT(item_id) DO UPDATE SET result=excluded.result",
                               (identifier, json.dumps(result, ensure_ascii=False)))
                self._set_state(db, identifier, "complete")
                future.set_result(item_json(self.fetch_item(db, identifier)))
            except Exception as error:
                state = "disabled" if isinstance(error, vision.VisionError) and error.status == 503 else "failed"
                try:
                    self._set_state(db, identifier, state)
                except sqlite3.Error:
                    logging.error("Could not update tagging status")
                safe_error = error if isinstance(error, vision.VisionError) else vision.VisionError(502, "Tagging failed. Your photo is saved; please retry.")
                future.set_exception(safe_error)
            finally:
                db.close()
                with self.ai_lock:
                    self.ai_pending.pop(identifier, None)
                self.ai_queue.task_done()

    def server_close(self):
        self.ai_stopping.set()
        super().server_close()
        self.ai_worker.join(timeout=35)
        with self.ai_lock:
            while True:
                try:
                    identifier, future = self.ai_queue.get_nowait()
                except queue.Empty:
                    break
                self.ai_pending.pop(identifier, None)
                future.set_exception(vision.VisionError(503, "Server restarting. Your photo is saved."))
                self.ai_queue.task_done()


class PhotoHandler(BaseHTTPRequestHandler):
    server_version = "LostFoundDemo/1.0"

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def _send(self, status, body, mime_type="application/json; charset=utf-8", headers=None):
        if not isinstance(body, bytes):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", mime_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; img-src 'self' blob:; "
                         "media-src 'self' blob:; object-src 'none'; base-uri 'none'; "
                         "frame-ancestors 'none'; form-action 'self'")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _error(self, status, message):
        self._send(status, {"error": message})

    def send_error(self, code, message=None, explain=None):
        self.close_connection = True
        self._error(code, "Unsupported or invalid request")

    def do_GET(self):
        try:
            self._get()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except vision.VisionError as error:
            self._error(error.status, error.message)
        except (sqlite3.Error, OSError):
            logging.exception("读取失败")
            self._error(500, "Could not load data. Please retry later.")

    def do_HEAD(self):
        self.do_GET()

    def _get(self):
        path = self.path.partition("?")[0]
        if path.startswith("/api/admin/"):
            self._admin_get(path)
        elif path == "/api/health":
            self._send(200, {"ok": True})
        elif path == "/api/ai/status":
            self._send(200, vision.configuration_status())
        elif path == "/api/lockers":
            self._send(200, self.server.lockers.snapshot())
        elif path.startswith("/api/locker-operations/"):
            identifier = path[len("/api/locker-operations/"):]
            self._send(200, self.server.operation_response(self.server.lockers.get(identifier)))
        elif path == "/api/items":
            available = parse_qs(urlsplit(self.path).query).get("available") == ["1"]
            condition = ("WHERE item_storage.status='stored' AND compartments.state='occupied' "
                         "AND compartments.item_id=items.id") if available else ""
            db = self.server.connect_db()
            try:
                rows = db.execute("""SELECT items.id, created_at, note, recognitions.result AS recognition,
                    recognition_jobs.state AS recognition_state,
                    item_storage.status AS storage_status,item_storage.compartment_id
                    FROM items LEFT JOIN recognitions ON recognitions.item_id = items.id
                    LEFT JOIN recognition_jobs ON recognition_jobs.item_id = items.id
                    LEFT JOIN item_storage ON item_storage.item_id = items.id
                    LEFT JOIN compartments ON compartments.id = item_storage.compartment_id
                    """ + condition + " ORDER BY created_at DESC, items.rowid DESC LIMIT 100").fetchall()
                total = db.execute("SELECT COUNT(*) FROM items "
                                   "LEFT JOIN item_storage ON item_storage.item_id=items.id "
                                   "LEFT JOIN compartments ON compartments.id=item_storage.compartment_id " + condition).fetchone()[0]
            finally:
                db.close()
            self._send(200, {"items": [item_json(row) for row in rows], "total": total})
        elif path.startswith("/images/"):
            identifier = path[len("/images/"):]
            try:
                if str(uuid.UUID(identifier)) != identifier:
                    raise ValueError()
            except ValueError:
                self._error(404, "Photo not found")
                return
            db = self.server.connect_db()
            try:
                row = db.execute("SELECT mime_type, image FROM items WHERE id = ?", (identifier,)).fetchone()
            finally:
                db.close()
            if row is None:
                self._error(404, "Photo not found")
            else:
                self._send(200, row["image"], row["mime_type"])
        else:
            allowed = {"/": ("index.html", "text/html; charset=utf-8"),
                       "/admin": ("admin.html", "text/html; charset=utf-8"),
                       "/admin/": ("admin.html", "text/html; charset=utf-8"),
                       "/admin/admin.css": ("admin.css", "text/css; charset=utf-8"),
                       "/admin/admin.js": ("admin.js", "text/javascript; charset=utf-8"),
                       "/app.js": ("app.js", "text/javascript; charset=utf-8"),
                       "/style.css": ("style.css", "text/css; charset=utf-8")}
            entry = allowed.get(path)
            if entry is None or not (STATIC_DIR / entry[0]).is_file():
                self._error(404, "Page not found")
                return
            self._send(200, (STATIC_DIR / entry[0]).read_bytes(), entry[1])

    def _admin_get(self, path):
        admin = self.server.admin
        cookie = self.headers.get("Cookie")
        if path == "/api/admin/session":
            self._send(200, {"configured": admin.sessions.configured,
                             "authenticated": admin.sessions.authenticated(cookie)})
            return
        admin.sessions.require(cookie)
        if path == "/api/admin/overview":
            self._send(200, admin.overview(isinstance(self.connection, ssl.SSLSocket)))
        elif path == "/api/admin/items":
            self._send(200, admin.items(parse_qs(urlsplit(self.path).query, keep_blank_values=True)))
        elif path.startswith("/api/admin/manual-open/"):
            self._send(200, {"operation": self.server.lockers.manual_get(path[len('/api/admin/manual-open/'):])})
        else:
            self._error(404, "Endpoint not found")

    def _admin_post(self, path, payload):
        admin = self.server.admin
        cookie = self.headers.get("Cookie")
        secure = isinstance(self.connection, ssl.SSLSocket)
        if path == "/api/admin/login":
            if set(payload) != {"password"}:
                raise vision.VisionError(400, "Provide the administrator password.")
            token = admin.sessions.login(payload["password"], self.client_address[0])
            admin.sessions.logout(cookie)
            self._send(200, {"authenticated": True}, headers={"Set-Cookie": admin.sessions.cookie(token, secure)})
            return
        if path == "/api/admin/logout":
            if payload:
                raise vision.VisionError(400, "The sign-out request must be an empty object.")
            admin.sessions.logout(cookie)
            self._send(200, {"authenticated": False}, headers={"Set-Cookie": admin.sessions.cookie("", secure)})
            return
        if path == "/api/admin/manual-open":
            if set(payload) != {"request_id", "compartment_id", "reason"}:
                raise vision.VisionError(400, "Provide the request ID, compartment ID and reason for opening.")
            operation, duplicate = self.server.lockers.manual_open(
                payload["request_id"], payload["compartment_id"], payload["reason"])
            self._send(200 if duplicate else 201, {"operation": operation, "duplicate": duplicate})
            return
        parts = path[len("/api/admin/"):].split("/")
        if len(parts) != 3:
            raise vision.VisionError(404, "Endpoint not found")
        category, identifier, action = parts
        identifier = lockers.canonical_uuid(identifier)
        if category == "manual-open" and action == "confirm":
            if payload:
                raise vision.VisionError(400, "The confirmation request must be an empty object.")
            self._send(200, {"operation": self.server.lockers.manual_confirm(identifier)})
        elif category == "locker-operations" and action == "resolve":
            if set(payload) != {"outcome"} or not isinstance(payload["outcome"], str):
                raise vision.VisionError(400, "Select the outcome of the physical inspection.")
            operation = self.server.lockers.finish(identifier, payload["outcome"])
            self._send(200, self.server.operation_response(operation))
        elif category == "items" and action == "recognize":
            if payload:
                raise vision.VisionError(400, "The recognition request must be an empty object.")
            self.server.enqueue_recognition(identifier)
            self._send(202, {"queued": True, "item_id": identifier})
        else:
            raise vision.VisionError(404, "Endpoint not found")

    def _same_origin(self):
        origin = self.headers.get("Origin")
        if origin is None:
            return True
        scheme = "https" if isinstance(self.connection, ssl.SSLSocket) else "http"
        try:
            source = urlsplit(origin)
            target = urlsplit(scheme + "://" + self.headers.get("Host", ""))
            default_port = 443 if scheme == "https" else 80
            return (source.scheme == scheme and bool(source.hostname) and
                    source.hostname == target.hostname and
                    (source.port or default_port) == (target.port or default_port) and
                    not source.username and not source.password and
                    not source.path and not source.query and not source.fragment)
        except ValueError:
            return False

    def do_POST(self):
        # HTTP/1.0 responses close the connection, including on rejected unread bodies.
        try:
            self._post()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except vision.VisionError as error:
            self._error(error.status, error.message)
        except (TimeoutError, OSError):
            self._error(408, "Upload timed out or connection lost. Please retry.")
        except sqlite3.Error:
            logging.exception("保存失败")
            self._error(500, "Could not save. Please retry later.")

    def _post(self):
        path = self.path.partition("?")[0]
        identifier = None
        locker_action = None
        admin_request = path.startswith("/api/admin/")
        if admin_request:
            if path != "/api/admin/login":
                self.server.admin.sessions.require(self.headers.get("Cookie"))
        elif path.startswith("/api/items/") and path.endswith("/recognize"):
            identifier = path[len("/api/items/"):-len("/recognize")]
            try:
                if str(uuid.UUID(identifier)) != identifier:
                    raise ValueError()
            except ValueError:
                self._error(404, "Item not found")
                return
        elif path.startswith("/api/locker-operations/"):
            parts = path[len("/api/locker-operations/"):].split("/")
            if len(parts) != 2 or parts[1] not in ("complete", "resolve"):
                self._error(404, "Endpoint not found")
                return
            locker_action = (lockers.canonical_uuid(parts[0]), parts[1])
        elif path not in ("/api/items", "/api/search", "/api/transcribe", "/api/locker-operations"):
            self._error(404, "Endpoint not found")
            return
        if self.headers.get("X-Requested-With") != "lost-found-box" or not self._same_origin():
            self._error(403, "Request origin not allowed. Submit from this application.")
            return
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") or len(lengths) != 1 or not lengths[0].isascii() or not lengths[0].isdigit():
            self._error(400, "Missing or invalid request length")
            return
        body_limit, size_error = {
            "/api/search": (MAX_SEARCH_BODY_BYTES, "Search request exceeds 16 KiB."),
            "/api/transcribe": (speech.MAX_BODY_BYTES, "Speech request exceeds 1.4 MB. Please record a shorter description."),
        }.get(path, (MAX_BODY_BYTES, "Upload too large. Please take another photo."))
        if path.startswith("/api/locker-operations") or admin_request:
            body_limit, size_error = MAX_SEARCH_BODY_BYTES, "Locker request exceeds 16 KiB."
        if len(lengths[0]) > 12:
            self._error(413, size_error)
            return
        length = int(lengths[0])
        if length > body_limit:
            self._error(413, size_error)
            return
        if self.headers.get_content_type() != "application/json":
            self._error(415, "Request must use JSON")
            return
        raw = self.rfile.read(length)
        if len(raw) != length:
            self._error(400, "Incomplete upload. Please retry.")
            return
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError, RecursionError):
            self._error(400, "Invalid JSON")
            return
        if not isinstance(payload, dict):
            self._error(400, "Request must be a JSON object")
            return
        if admin_request:
            self._admin_post(path, payload)
            return
        if path == "/api/locker-operations":
            if set(payload) != {"request_id", "item_id", "kind"}:
                self._error(400, "Provide request_id, item_id and kind.")
                return
            operation, duplicate = self.server.lockers.start(payload["request_id"], payload["item_id"], payload["kind"])
            self._send(200 if duplicate else 201, self.server.operation_response(operation))
            return
        if locker_action is not None:
            operation_id, action = locker_action
            if (action == "complete" and payload) or (action == "resolve" and set(payload) != {"outcome"}):
                self._error(400, "Complete accepts {}; resolve requires an outcome.")
                return
            if action == "resolve" and not isinstance(payload["outcome"], str):
                self._error(400, "Resolution outcome must be text.")
                return
            operation = self.server.lockers.finish(operation_id, payload.get("outcome"))
            self._send(200, self.server.operation_response(operation))
            return
        if path == "/api/transcribe":
            audio = speech.decode_audio(payload)
            self._send(200, {"text": self.server.transcribe_audio(audio)})
            return
        if path == "/api/search":
            query = payload.get("query")
            if not isinstance(query, str) or not 1 <= len(query.strip()) <= 500:
                self._error(400, "Describe your item in 1 to 500 characters.")
                return
            try:
                query.encode("utf-8")
            except UnicodeError:
                self._error(400, "Invalid description text.")
                return
            self._send(200, self.server.search_items(query.strip()))
            return
        if identifier is not None:
            if payload:
                self._error(400, "Tagging request must be an empty JSON object")
                return
            self._send(200, {"item": self.server.recognize_item(identifier)})
            return
        note, encoded = payload.get("note", ""), payload.get("image")
        mime_type, request_id = payload.get("mime_type"), payload.get("request_id")
        if not isinstance(note, str) or len(note) > 200:
            self._error(400, "Notes must be no more than 200 characters")
            return
        if mime_type not in ("image/jpeg", "image/png") or not isinstance(encoded, str):
            self._error(400, "Please submit a JPEG or PNG photo")
            return
        try:
            request_id = str(uuid.UUID(request_id)) if isinstance(request_id, str) else None
            if request_id is None:
                raise ValueError()
            image = base64.b64decode(encoded, validate=True)
            # Reject escaped surrogate characters before hashing or database writes.
            note.encode("utf-8")
        except (ValueError, binascii.Error, UnicodeError):
            self._error(400, "Invalid image encoding, note or request ID")
            return
        if len(image) > MAX_IMAGE_BYTES:
            self._error(413, "Photo exceeds 5 MiB. Resize it and retry.")
            return
        try:
            validate_image(image, mime_type)
        except (InvalidImage, struct.error):
            self._error(400, "Invalid photo format or dimensions. Please take another photo.")
            return
        fingerprint = hashlib.sha256(mime_type.encode() + b"\0" + note.encode() + b"\0" + image).hexdigest()
        db = self.server.connect_db()
        try:
            with db:
                db.execute("BEGIN IMMEDIATE")
                existing = db.execute("SELECT id, created_at, note, fingerprint FROM items WHERE request_id = ?", (request_id,)).fetchone()
                if existing is not None:
                    if existing["fingerprint"] != fingerprint:
                        self._error(409, "This request ID was used for other content. Please choose the photo again.")
                        return
                    result, duplicate = item_json(self.server.fetch_item(db, existing["id"])), True
                else:
                    identifier = str(uuid.uuid4())
                    db.execute("INSERT INTO items VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), ?, ?, ?)",
                               (identifier, request_id, fingerprint, note, mime_type, image))
                    result = item_json(db.execute("SELECT id, created_at, note FROM items WHERE id = ?", (identifier,)).fetchone())
                    duplicate = False
        finally:
            db.close()
        if self.server.auto_recognize:
            try:
                self.server.enqueue_recognition(result["id"], automatic=True)
            except vision.VisionError:
                pass  # Registration succeeds independently of recognition/configuration.
            db = self.server.connect_db()
            try:
                result = item_json(self.server.fetch_item(db, result["id"]))
            finally:
                db.close()
        self._send(200 if duplicate else 201, {"item": result, "duplicate": duplicate})


def build_server(host, port, data_dir, cert=None, key=None, auto_recognize=True,
                 locker_mode=None, locker_driver=None):
    if bool(cert) != bool(key):
        raise ValueError("--cert 和 --key 必须一起提供")
    try:
        loopback = ipaddress.ip_address(host).is_loopback
    except ValueError:
        loopback = host.lower() == "localhost"
    if not cert and not loopback:
        raise ValueError("局域网访问需要 HTTPS，请同时提供 --cert 和 --key")
    driver = locker_driver if locker_driver is not None else lockers.configured_driver(host, locker_mode)
    if driver is not None and driver.name == "simulated" and not loopback:
        raise ValueError("Simulated lockers may only listen on localhost.")
    context = None
    if cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, key)
    server = PhotoServer((host, port), data_dir, auto_recognize=auto_recognize, locker_driver=driver)
    if context:
        server.socket = context.wrap_socket(server.socket, server_side=True)
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--data-dir", type=Path, default=Path(__file__).resolve().parent / "data")
    parser.add_argument("--cert")
    parser.add_argument("--key")
    parser.add_argument("--locker-mode", choices=("disabled", "simulated", "gpio"),
                        help="defaults to LOST_FOUND_LOCKER_MODE or disabled; simulation is localhost only")
    args = parser.parse_args()
    try:
        server = build_server(args.host, args.port, args.data_dir, args.cert, args.key, locker_mode=args.locker_mode)
    except (ValueError, OSError, ssl.SSLError) as error:
        parser.error(str(error))
    scheme = "https" if args.cert else "http"
    print("课堂可信网络演示服务：{}://{}:{}".format(scheme, args.host, server.server_port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
