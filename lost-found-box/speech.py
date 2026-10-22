"""Bounded short-recording transcription through Alibaba Bailian (stdlib only)."""

import base64
import binascii
from http.client import HTTPException
import io
import json
import socket
import struct
import unicodedata
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import ProxyHandler, Request, build_opener
import wave

import vision


MODEL = "qwen3-asr-flash"
MAX_AUDIO_BYTES = 1_000_000
MAX_BODY_BYTES = 1_400_000
MAX_RESPONSE_BYTES = 64 * 1024
MIN_FRAMES = 4800  # 0.3 seconds at 16 kHz.
MAX_FRAMES = 488000  # 30.5 seconds, allowing the recorder's stop callback to finish.


def invalid_audio():
    return vision.VisionError(400, "The recording could not be read. Please record again or type your description.")


def validate_wav(audio):
    """Check the full RIFF container as well as wave's decoded frame metadata."""
    if len(audio) > MAX_AUDIO_BYTES:
        raise vision.VisionError(413, "Speech recording exceeds 1 MB. Please record a shorter description.")
    try:
        if (len(audio) < 44 or audio[:4] != b"RIFF" or audio[8:12] != b"WAVE" or
                struct.unpack_from("<I", audio, 4)[0] + 8 != len(audio)):
            raise ValueError()
        offset, seen_format, data_size = 12, False, None
        while offset < len(audio):
            if offset + 8 > len(audio):
                raise ValueError()
            kind, size = struct.unpack_from("<4sI", audio, offset)
            start, end = offset + 8, offset + 8 + size
            if end + size % 2 > len(audio):
                raise ValueError()
            if kind == b"fmt ":
                if seen_format or data_size is not None or size < 16:
                    raise ValueError()
                if struct.unpack_from("<HHIIHH", audio, start) != (1, 1, 16000, 32000, 2, 16):
                    raise ValueError()
                seen_format = True
            elif kind == b"data":
                if not seen_format or data_size is not None or size % 2:
                    raise ValueError()
                data_size = size
            offset = end + size % 2
        if data_size is None or not MIN_FRAMES <= data_size // 2 <= MAX_FRAMES:
            raise ValueError()
        with wave.open(io.BytesIO(audio), "rb") as recording:
            if (recording.getnchannels() != 1 or recording.getsampwidth() != 2 or
                    recording.getframerate() != 16000 or recording.getcomptype() != "NONE" or
                    recording.getnframes() != data_size // 2 or
                    len(recording.readframes(recording.getnframes() + 1)) != data_size):
                raise ValueError()
    except (ValueError, struct.error, wave.Error, EOFError):
        raise invalid_audio() from None


def decode_audio(payload):
    if (not isinstance(payload, dict) or set(payload) != {"audio", "mime_type"} or
            payload["mime_type"] != "audio/wav" or not isinstance(payload["audio"], str)):
        raise invalid_audio()
    encoded = payload["audio"]
    if len(encoded) > 4 * ((MAX_AUDIO_BYTES + 2) // 3):
        raise vision.VisionError(413, "Speech recording exceeds 1 MB. Please record a shorter description.")
    try:
        audio = base64.b64decode(encoded, validate=True)
        # Also reject extra padding and noncanonical padding bits.
        if base64.b64encode(audio).decode("ascii") != encoded:
            raise ValueError()
    except (ValueError, binascii.Error, UnicodeError):
        raise vision.VisionError(400, "Invalid speech recording encoding. Please record again.") from None
    validate_wav(audio)
    return audio


def invalid_response():
    return vision.VisionError(502, "Could not read the speech result. Please try again.")


def transcribe(audio):
    # The existing loader validates the credential and Beijing endpoint allowlist.
    try:
        config = vision.load_config()
    except vision.VisionError:
        raise vision.VisionError(503, "Speech configuration is invalid. Check the server settings.") from None
    if not config["api_key"]:
        raise vision.VisionError(503, "Speech recognition is not configured. Please type your description.")
    base = urlsplit(config["base_url"])
    endpoint = urlunsplit((base.scheme, base.netloc,
                          "/api/v1/services/aigc/multimodal-generation/generation", "", ""))
    payload = {
        "model": MODEL,
        "input": {"messages": [{"role": "user", "content": [
            {"audio": "data:audio/wav;base64," + base64.b64encode(audio).decode("ascii")}
        ]}]},
        "parameters": {"asr_options": {"enable_itn": False}},
    }
    request = Request(endpoint, data=json.dumps(payload).encode("utf-8"),
                      headers={"Authorization": "Bearer " + config["api_key"], "Content-Type": "application/json"},
                      method="POST")
    opener = build_opener(ProxyHandler({}), vision.NoRedirect())
    try:
        with opener.open(request, timeout=30) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
    except HTTPError as error:
        error.close()
        raise vision.VisionError(502, "Speech request failed. Check the configuration or retry later.") from None
    except (TimeoutError, socket.timeout):
        raise vision.VisionError(504, "Speech recognition timed out. Please try again.") from None
    except URLError as error:
        if isinstance(error.reason, (TimeoutError, socket.timeout)):
            raise vision.VisionError(504, "Speech recognition timed out. Please try again.") from None
        raise vision.VisionError(502, "Could not reach the speech service. Please try again.") from None
    except (OSError, HTTPException):
        raise vision.VisionError(502, "Could not reach the speech service. Please try again.") from None
    try:
        if len(raw) > MAX_RESPONSE_BYTES:
            raise ValueError()
        result = json.loads(raw)
        choices = result["output"]["choices"]
        if not isinstance(choices, list) or len(choices) != 1 or choices[0]["finish_reason"] != "stop":
            raise ValueError()
        message = choices[0]["message"]
        content = message["content"]
        if message["role"] != "assistant" or not isinstance(content, list) or len(content) != 1:
            raise ValueError()
        text = content[0]["text"]
        if not isinstance(text, str) or any(unicodedata.category(char) in ("Cc", "Cf", "Cs") for char in text):
            raise ValueError()
        text = text.strip()
    except (ValueError, KeyError, IndexError, TypeError, AttributeError, RecursionError):
        raise invalid_response() from None
    if not text:
        raise vision.VisionError(422, "No speech was recognized. Please record again or type your description.")
    if len(text) > 500:
        raise vision.VisionError(422, "Speech is too long. Please say a shorter description.")
    return text
