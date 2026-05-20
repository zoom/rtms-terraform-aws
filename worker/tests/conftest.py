"""Shared fixtures derived from spec.md acceptance criteria."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import time
from typing import Any
from unittest.mock import MagicMock


WEBHOOK_SECRET    = "test-webhook-secret"
TRANSCRIPT_BUCKET = "rtms-test-transcripts"
AWS_REGION        = "us-east-1"

# Set env vars *before* anything imports main.py — main.py validates these at
# import time and exits on missing required values.
os.environ.setdefault("ZM_RTMS_WEBHOOK_SECRET",    WEBHOOK_SECRET)
os.environ.setdefault("TRANSCRIPT_BUCKET",         TRANSCRIPT_BUCKET)
os.environ.setdefault("AWS_REGION",                AWS_REGION)
os.environ.setdefault("EVENTLOOP_THREADS",         "2")
os.environ.setdefault("CALLBACK_EXECUTOR_WORKERS", "4")
os.environ.setdefault("LOG_LEVEL",                 "INFO")
os.environ.setdefault("AWS_ACCESS_KEY_ID",         "test")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY",     "test")

import boto3  # noqa: E402
import pytest  # noqa: E402
from moto import mock_aws  # noqa: E402


@pytest.fixture
def s3_bucket():
    with mock_aws():
        s3 = boto3.client("s3", region_name=AWS_REGION)
        s3.create_bucket(Bucket=TRANSCRIPT_BUCKET)
        yield s3


def sign_webhook(body: bytes, timestamp: str,
                 secret: str = WEBHOOK_SECRET) -> str:
    msg = b"v0:" + timestamp.encode() + b":" + body
    return "v0=" + hmac.new(secret.encode(), msg, hashlib.sha256).hexdigest()


class MockRequest:
    """Stands in for the rtms package's request object passed to handlers."""

    def __init__(self, headers: dict[str, str] | None = None):
        self.headers = headers or {}


class MockResponse:
    """Captures status + body so tests can assert on them."""

    def __init__(self):
        self.status: int = 200
        self.body: Any = None
        self.sent: bool = False

    def set_status(self, code: int):
        self.status = code

    def send(self, body: Any):
        self.body = body
        self.sent = True


@pytest.fixture
def make_request_with_signature():
    """Factory: returns (webhook_dict, MockRequest) signed the same way Zoom does.

    Zoom signs `JSON.stringify(body)` — no whitespace separators, ensure_ascii
    off. Tests must sign the same canonical form or the worker's HMAC check
    (which uses _canonical_body) will reject them."""

    def _make(event: str, payload: dict[str, Any], timestamp: str | None = None):
        webhook = {"event": event, "payload": payload}
        body_bytes = json.dumps(
            webhook, separators=(",", ":"), ensure_ascii=False,
        ).encode("utf-8")
        ts = timestamp or str(int(time.time()))
        sig = sign_webhook(body_bytes, ts)
        return webhook, MockRequest({
            "x-zm-signature": sig,
            "x-zm-request-timestamp": ts,
        })

    return _make


@pytest.fixture
def rtms_started_payload() -> dict:
    return {
        "meeting_uuid":   "abcdEFGH1234567890==",
        "rtms_stream_id": "stream-aaaabbbb",
        "server_urls":    "wss://rtms.example.com",
        "signature":      "ZOOM_RTMS_JOIN_SIG",
    }


@pytest.fixture
def rtms_stopped_payload(rtms_started_payload) -> dict:
    return {
        "meeting_uuid":   rtms_started_payload["meeting_uuid"],
        "rtms_stream_id": rtms_started_payload["rtms_stream_id"],
    }


@pytest.fixture
def fake_metadata():
    md = MagicMock()
    md.userId   = 42
    md.userName = "Alice"
    return md


@pytest.fixture
def reset_clients(monkeypatch):
    """Replace rtms.Client / EventLoopPool with stubs and clear shared state."""
    import main

    class StubClient:
        instances: list = []

        def __init__(self, *a, **kw):
            self.joined_with = None
            self.left = False
            self.callbacks: dict = {}
            StubClient.instances.append(self)

        def on_join_confirm(self, cb):    self.callbacks["join_confirm"] = cb; return cb
        def on_transcript_data(self, cb): self.callbacks["transcript"] = cb; return cb
        def on_audio_data(self, cb):      self.callbacks["audio"] = cb; return cb
        def on_leave(self, cb):           self.callbacks["leave"] = cb; return cb
        def on_media_connection_interrupted(self, cb):
            self.callbacks["media_interrupted"] = cb; return cb
        def join(self, payload):          self.joined_with = payload
        def leave(self):                  self.left = True

    class StubPool:
        def __init__(self):
            self.added: list = []

        def add(self, client):  self.added.append(client)
        def run(self):          pass
        def stop(self):         pass

    StubClient.instances = []
    stub_pool = StubPool()
    monkeypatch.setattr(main.rtms, "Client", StubClient)
    monkeypatch.setattr(main, "pool", stub_pool)
    main.clients.clear()
    main.stream_payloads.clear()
    main.reconnect_attempt.clear()
    yield StubClient
    main.clients.clear()
    main.stream_payloads.clear()
    main.reconnect_attempt.clear()
