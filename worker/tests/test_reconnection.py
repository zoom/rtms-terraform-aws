"""Tests for the three RTMS reconnection scenarios.

Scenario 1: meeting.rtms_started arrives for an existing stream with NEW
            server_urls (server failover). Old client torn down, new joined.

Scenario 2: meeting.rtms_interrupted webhook arrives. Old client torn down,
            new client joined with the fresh credentials from the webhook.

Scenario 3: on_media_connection_interrupted callback fires (signaling still
            up). client.join() is re-issued with the stored payload after
            an exponential backoff delay.
"""

from __future__ import annotations

import time

import main


# ------------------------- Scenario 1 -------------------------------------

def test_duplicate_started_with_same_server_urls_is_noop(reset_clients, rtms_started_payload):
    """Pure Zoom retry — same server_urls, no rejoin."""
    main.start_meeting(rtms_started_payload)
    main.start_meeting(rtms_started_payload)
    assert len(reset_clients.instances) == 1


def test_started_with_new_server_urls_tears_down_old_client(
    reset_clients, rtms_started_payload,
):
    """Server failover (Scenario 1) — fresh server_urls means new RTMS server."""
    main.start_meeting(rtms_started_payload)
    first_client = reset_clients.instances[0]

    failover_payload = dict(rtms_started_payload)
    failover_payload["server_urls"] = "wss://rtms-replacement.example.com"
    main.start_meeting(failover_payload)

    assert len(reset_clients.instances) == 2
    # Old client received a leave()
    assert first_client.left is True
    # New client joined with the new payload
    assert reset_clients.instances[1].joined_with["server_urls"] == \
        "wss://rtms-replacement.example.com"


# ------------------------- Scenario 2 -------------------------------------

def test_rtms_interrupted_webhook_tears_down_and_rejoins(
    reset_clients, rtms_started_payload,
):
    """meeting.rtms_interrupted — signaling dropped, fresh creds in payload."""
    main.start_meeting(rtms_started_payload)
    first_client = reset_clients.instances[0]

    interrupted_payload = dict(rtms_started_payload)
    interrupted_payload["signature"] = "FRESH_SIGNATURE_FROM_INTERRUPTED"
    main.handle_interrupted(interrupted_payload)

    assert len(reset_clients.instances) == 2
    assert first_client.left is True
    assert reset_clients.instances[1].joined_with["signature"] == \
        "FRESH_SIGNATURE_FROM_INTERRUPTED"


def test_rtms_interrupted_with_missing_stream_id_is_noop(reset_clients):
    main.handle_interrupted({"meeting_uuid": "no-stream-id"})
    assert len(reset_clients.instances) == 0


def test_rtms_interrupted_via_process_webhook(
    reset_clients, make_request_with_signature, rtms_started_payload,
):
    """End-to-end: signed meeting.rtms_interrupted goes through process_webhook."""
    start_wh, start_req = make_request_with_signature(
        "meeting.rtms_started", rtms_started_payload
    )
    main.process_webhook(start_wh, start_req, _MockResponse())

    interrupted_payload = dict(rtms_started_payload)
    interrupted_payload["signature"] = "NEW_SIG"
    wh, req = make_request_with_signature(
        "meeting.rtms_interrupted", interrupted_payload
    )
    main.process_webhook(wh, req, _MockResponse())

    assert len(reset_clients.instances) == 2


# ------------------------- Scenario 3 -------------------------------------

def test_media_connection_interrupted_schedules_reconnect(
    monkeypatch, reset_clients, rtms_started_payload,
):
    """on_media_connection_interrupted fires → client.join called again after backoff."""
    # Speed up the timer for the test
    monkeypatch.setattr(main, "RECONNECT_BACKOFF_BASE", 0)
    monkeypatch.setattr(main, "RECONNECT_BACKOFF_CAP", 0)

    main.start_meeting(rtms_started_payload)
    client = reset_clients.instances[0]
    assert client.joined_with == rtms_started_payload

    # Reset the joined_with marker to detect the re-join call
    client.joined_with = None

    # Trigger the callback the SDK would normally fire
    media_cb = client.callbacks["media_interrupted"]
    media_cb("network-blip")

    # The reconnect is scheduled via threading.Timer with delay=0 — give it
    # a beat to run.
    time.sleep(0.2)
    assert client.joined_with == rtms_started_payload


def test_reconnect_backoff_grows_exponentially():
    main.RECONNECT_BACKOFF_BASE = 3
    main.RECONNECT_BACKOFF_CAP  = 30
    assert main._backoff_seconds(1) == 3    # 3 * 2^0
    assert main._backoff_seconds(2) == 6    # 3 * 2^1
    assert main._backoff_seconds(3) == 12   # 3 * 2^2
    assert main._backoff_seconds(4) == 24   # 3 * 2^3
    assert main._backoff_seconds(5) == 30   # capped
    assert main._backoff_seconds(6) == 30   # still capped


def test_reconnect_attempt_counter_resets_on_join_confirm(
    reset_clients, rtms_started_payload,
):
    main.start_meeting(rtms_started_payload)
    stream_id = rtms_started_payload["rtms_stream_id"]
    main.reconnect_attempt[stream_id] = 3

    # Simulate a successful (re)join
    join_confirm_cb = reset_clients.instances[0].callbacks["join_confirm"]
    join_confirm_cb(0)

    assert main.reconnect_attempt[stream_id] == 0


def test_reconnect_gives_up_after_max_attempts(
    monkeypatch, reset_clients, rtms_started_payload,
):
    monkeypatch.setattr(main, "RECONNECT_MAX_ATTEMPTS", 2)

    main.start_meeting(rtms_started_payload)
    stream_id = rtms_started_payload["rtms_stream_id"]
    main.reconnect_attempt[stream_id] = 2  # already at limit

    main._schedule_media_reconnect(stream_id)

    # After giving up, the client should be removed and leave() called
    assert stream_id not in main.clients
    assert reset_clients.instances[0].left is True


# ------------------------- helpers ----------------------------------------

class _MockResponse:
    def __init__(self):
        self.status = 200
        self.body = None
    def set_status(self, code):  self.status = code
    def send(self, body):        self.body = body
