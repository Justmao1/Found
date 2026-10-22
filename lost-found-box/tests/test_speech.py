import base64
from http.client import IncompleteRead
import io
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError
import wave

import speech
import vision


def wav(frames=8000, channels=1, rate=16000, width=2):
    output = io.BytesIO()
    with wave.open(output, "wb") as recording:
        recording.setnchannels(channels)
        recording.setsampwidth(width)
        recording.setframerate(rate)
        recording.writeframes(b"\x01" * frames * channels * width)
    return output.getvalue()


def response(text="a blue water bottle", finish_reason="stop"):
    return {"output": {"choices": [{"finish_reason": finish_reason,
                                   "message": {"role": "assistant", "content": [{"text": text}]}}]}}


class AudioValidationTests(unittest.TestCase):
    def decode(self, recording, **updates):
        payload = {"audio": base64.b64encode(recording).decode("ascii"), "mime_type": "audio/wav"}
        payload.update(updates)
        return speech.decode_audio(payload)

    def assert_invalid(self, recording, status=400, **updates):
        with self.assertRaises(vision.VisionError) as caught:
            self.decode(recording, **updates)
        self.assertEqual(caught.exception.status, status)

    def test_duration_boundaries_and_complete_frames(self):
        for frames in (4800, 8000, 488000):
            audio = wav(frames=frames)
            self.assertEqual(self.decode(audio), audio)
        for frames in (0, 4799, 488001):
            self.assert_invalid(wav(frames=frames))

    def test_pcm_format_is_checked_from_audio_not_mime(self):
        for audio in (b"not audio", wav(channels=2), wav(rate=44100), wav(width=1), wav(width=3)):
            self.assert_invalid(audio)
        self.assert_invalid(wav(), mime_type="audio/m4a")
        for offset, fmt, value in ((20, "<H", 3), (28, "<I", 123), (32, "<H", 1)):
            audio = bytearray(wav())
            struct.pack_into(fmt, audio, offset, value)
            self.assert_invalid(bytes(audio))

    def test_truncated_and_mismatched_containers_are_rejected(self):
        audio = wav()
        malformed = [audio[:-1], audio + b"extra", audio[:43]]
        for declared in (15998, 16002, 16001):
            changed = bytearray(audio)
            struct.pack_into("<I", changed, 40, declared)
            malformed.append(bytes(changed))
        truncated = bytearray(audio[:-2])
        struct.pack_into("<I", truncated, 4, len(truncated) - 8)
        malformed.append(bytes(truncated))
        duplicate = audio + b"data" + struct.pack("<I", 2) + b"\0\0"
        duplicate = duplicate[:4] + struct.pack("<I", len(duplicate) - 8) + duplicate[8:]
        malformed.append(duplicate)
        for value in malformed:
            self.assert_invalid(value)

    def test_bounded_ancillary_chunks_are_accepted(self):
        audio = wav()
        audio = audio[:12] + b"JUNK" + struct.pack("<I", 3) + b"abc\0" + audio[12:]
        audio = audio[:4] + struct.pack("<I", len(audio) - 8) + audio[8:]
        self.assertEqual(self.decode(audio), audio)
        self.assert_invalid(audio[:-1])

    def test_strict_base64_and_request_shape(self):
        encoded = base64.b64encode(wav()).decode("ascii")
        invalid = (None, 1, "", "data:audio/wav;base64," + encoded, encoded + "\n",
                   "_" + encoded[1:], encoded + "=", "é", "\ud800", "AAAA=AAA")
        for value in invalid:
            self.assert_invalid(wav(), audio=value)
        for payload in ({}, [], {"audio": encoded}, {"audio": encoded, "mime_type": "audio/wav", "url": "https://example.com"}):
            with self.assertRaises(vision.VisionError) as caught:
                speech.decode_audio(payload)
            self.assertEqual(caught.exception.status, 400)

    def test_file_size_limit(self):
        self.assert_invalid(b"x" * (speech.MAX_AUDIO_BYTES + 1), status=413)


class SpeechClientTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config_path = Path(self.directory.name) / "test-config.json"
        self.config = {"api_key": "unit-test-secret", "model": "qwen3-vl-plus",
                       "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1"}
        self.config_path.write_text(json.dumps(self.config))
        self.environment = patch.dict(os.environ, {"LOST_FOUND_AI_CONFIG": str(self.config_path)}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def call(self, result):
        opener = Mock()
        opener.open.return_value = io.BytesIO(json.dumps(result).encode())
        with patch("speech.build_opener", return_value=opener) as builder:
            text = speech.transcribe(wav())
        return text, opener, builder

    def test_native_payload_reuses_config_and_keeps_key_only_in_header(self):
        with patch("vision.load_config", wraps=vision.load_config) as config_loader:
            text, opener, builder = self.call(response("  蓝色水杯  "))
        self.assertEqual(text, "蓝色水杯")
        config_loader.assert_called_once_with()
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.get_header("Authorization"), "Bearer unit-test-secret")
        self.assertEqual(opener.open.call_args.kwargs, {"timeout": 30})
        payload = json.loads(request.data)
        self.assertEqual(payload, {"model": "qwen3-asr-flash", "input": {"messages": [
            {"role": "user", "content": [{"audio": "data:audio/wav;base64," + base64.b64encode(wav()).decode()}]}]},
            "parameters": {"asr_options": {"enable_itn": False}}})
        self.assertNotIn(b"unit-test-secret", request.data)
        handlers = builder.call_args.args
        self.assertEqual(handlers[0].proxies, {})
        self.assertIsInstance(handlers[1], vision.NoRedirect)
        self.assertIsNone(handlers[1].redirect_request(request, None, 302, "", {}, "https://example.com"))

    def test_workspace_host_and_environment_key_are_reused(self):
        self.config["base_url"] = "https://test-workspace.cn-beijing.maas.aliyuncs.com:443/compatible-mode/v1/"
        self.config_path.write_text(json.dumps(self.config))
        with patch.dict(os.environ, {"DASHSCOPE_API_KEY": "environment-test-key"}):
            _, opener, _ = self.call(response())
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "https://test-workspace.cn-beijing.maas.aliyuncs.com:443/api/v1/services/aigc/multimodal-generation/generation")
        self.assertEqual(request.get_header("Authorization"), "Bearer environment-test-key")

    def test_invalid_or_missing_configuration_is_speech_specific(self):
        for config in ({}, {"api_key": "unit-test-secret", "base_url": "https://evil.example/compatible-mode/v1"}, []):
            self.config_path.write_text(json.dumps(config))
            with patch("speech.build_opener") as builder, self.assertRaises(vision.VisionError) as caught:
                speech.transcribe(wav())
            self.assertEqual(caught.exception.status, 503)
            self.assertIn("Speech", caught.exception.message)
            self.assertNotIn("unit-test-secret", caught.exception.message)
            builder.assert_not_called()

    def test_network_errors_are_redacted_and_not_retried(self):
        http_body = io.BytesIO(b"unit-test-secret provider diagnostics")
        errors = ((HTTPError("https://example.com", 401, "unit-test-secret", {}, http_body), 502),
                  (URLError("unit-test-secret"), 502), (TimeoutError("unit-test-secret"), 504),
                  (URLError(TimeoutError("unit-test-secret")), 504), (IncompleteRead(b"secret", 4), 502))
        for error, status in errors:
            opener = Mock()
            opener.open.side_effect = error
            with patch("speech.build_opener", return_value=opener), self.assertRaises(vision.VisionError) as caught:
                speech.transcribe(wav())
            self.assertEqual(caught.exception.status, status)
            self.assertNotIn("secret", caught.exception.message)
            self.assertIn("speech", caught.exception.message.lower())
            opener.open.assert_called_once()
        self.assertTrue(http_body.closed)

    def test_invalid_response_shapes_finish_reason_and_controls(self):
        invalid = [None, [], {}, {"output": None}, {"output": {"choices": []}},
                   response(None), response(3), response("ok", "length"), response("ok", None),
                   response("unit-test-secret\n"), response("a\x00b"), response("a\x7fb"),
                   response("a\u202eb"), response("\ud800")]
        for value in (None, [], "plain text", [{"text": "ok"}, {"text": "extra"}]):
            result = response()
            result["output"]["choices"][0]["message"]["content"] = value
            invalid.append(result)
        result = response()
        result["output"]["choices"][0]["message"]["role"] = "user"
        invalid.append(result)
        result = response()
        result["output"]["choices"] *= 2
        invalid.append(result)
        for result in invalid:
            with self.subTest(result=str(result)[:100]), self.assertRaises(vision.VisionError) as caught:
                self.call(result)
            self.assertEqual(caught.exception.status, 502)
            self.assertNotIn("secret", caught.exception.message)

    def test_blank_and_overlong_transcripts_are_user_recoverable(self):
        for text in ("", "  ", "字" * 501):
            with self.assertRaises(vision.VisionError) as caught:
                self.call(response(text))
            self.assertEqual(caught.exception.status, 422)
        text, _, _ = self.call(response("字" * 500))
        self.assertEqual(len(text), 500)

    def test_provider_response_is_bounded_and_invalid_json_is_safe(self):
        for raw in (b"x" * (speech.MAX_RESPONSE_BYTES + 1), b"{", b"\xff", b"[" * 2000):
            stream = Mock(wraps=io.BytesIO(raw))
            stream.__enter__ = Mock(return_value=stream)
            stream.__exit__ = Mock(return_value=False)
            opener = Mock()
            opener.open.return_value = stream
            with patch("speech.build_opener", return_value=opener), self.assertRaises(vision.VisionError) as caught:
                speech.transcribe(wav())
            self.assertEqual(caught.exception.status, 502)
            stream.read.assert_called_once_with(speech.MAX_RESPONSE_BYTES + 1)


if __name__ == "__main__":
    unittest.main()
