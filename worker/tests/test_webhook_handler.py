"""AC#1, #2, #4, #6 — process_webhook routes events correctly."""

from __future__ import annotations

import json
import time

import main

from .conftest import MockRequest, MockResponse, WEBHOOK_SECRET


# ---------- AC #1 — CRC handshake ----------

def test_url_validation_returns_crc_response(reset_clients):
    response = MockResponse()
    main.process_webhook(
        {"event": "endpoint.url_validation",
         "payload": {"plainToken": "test-plain"}},
        MockRequest(),
        response,
    )
    assert response.body["plainToken"] == "test-plain"
    assert len(response.body["encryptedToken"]) == 64  # SHA-256 hex


def test_url_validation_does_not_require_signature_headers(reset_clients):
    """CRC arrives before signing keys are exchanged — skip the HMAC check."""
    response = MockResponse()
    main.process_webhook(
        {"event": "endpoint.url_validation",
         "payload": {"plainToken": "abc"}},
        MockRequest(headers={}),
        response,
    )
    assert response.status == 200
    assert response.body["plainToken"] == "abc"


# ---------- AC #2 — signature accept/reject ----------

def test_valid_signature_accepted(
    reset_clients, make_request_with_signature, rtms_started_payload,
):
    webhook, request = make_request_with_signature(
        "meeting.rtms_started", rtms_started_payload
    )
    response = MockResponse()
    main.process_webhook(webhook, request, response)
    assert response.status == 200


def test_invalid_signature_returns_401(reset_clients, rtms_started_payload):
    webhook = {"event": "meeting.rtms_started", "payload": rtms_started_payload}
    request = MockRequest({
        "x-zm-signature": "v0=deadbeef",
        "x-zm-request-timestamp": str(int(time.time())),
    })
    response = MockResponse()
    main.process_webhook(webhook, request, response)
    assert response.status == 401


def test_missing_signature_headers_returns_401(reset_clients, rtms_started_payload):
    webhook = {"event": "meeting.rtms_started", "payload": rtms_started_payload}
    response = MockResponse()
    main.process_webhook(webhook, MockRequest(headers={}), response)
    assert response.status == 401


def test_invalid_signature_does_not_trigger_join(
    reset_clients, rtms_started_payload,
):
    webhook = {"event": "meeting.rtms_started", "payload": rtms_started_payload}
    request = MockRequest({
        "x-zm-signature": "v0=bad",
        "x-zm-request-timestamp": str(int(time.time())),
    })
    main.process_webhook(webhook, request, MockResponse())
    assert len(reset_clients.instances) == 0


# ---------- AC #4 — meeting.rtms_started triggers join ----------

def test_rtms_started_creates_client_and_joins(
    reset_clients, make_request_with_signature, rtms_started_payload,
):
    webhook, request = make_request_with_signature(
        "meeting.rtms_started", rtms_started_payload
    )
    main.process_webhook(webhook, request, MockResponse())

    assert len(reset_clients.instances) == 1
    assert reset_clients.instances[0].joined_with == rtms_started_payload


def test_rtms_started_registers_transcript_and_leave_callbacks(
    reset_clients, make_request_with_signature, rtms_started_payload,
):
    webhook, request = make_request_with_signature(
        "meeting.rtms_started", rtms_started_payload
    )
    main.process_webhook(webhook, request, MockResponse())

    cb = reset_clients.instances[0].callbacks
    assert "transcript" in cb
    assert "leave" in cb


# ---------- AC #6 — meeting.rtms_stopped triggers leave ----------

def test_rtms_stopped_calls_leave(
    reset_clients, make_request_with_signature,
    rtms_started_payload, rtms_stopped_payload,
):
    started_webhook, started_request = make_request_with_signature(
        "meeting.rtms_started", rtms_started_payload
    )
    main.process_webhook(started_webhook, started_request, MockResponse())

    stopped_webhook, stopped_request = make_request_with_signature(
        "meeting.rtms_stopped", rtms_stopped_payload
    )
    main.process_webhook(stopped_webhook, stopped_request, MockResponse())

    assert reset_clients.instances[0].left is True


def test_rtms_stopped_for_unknown_stream_is_noop(
    reset_clients, make_request_with_signature, rtms_stopped_payload,
):
    webhook, request = make_request_with_signature(
        "meeting.rtms_stopped", rtms_stopped_payload
    )
    main.process_webhook(webhook, request, MockResponse())
    assert len(reset_clients.instances) == 0


# ---------- response timing — keep handler fast (Zoom ACK SLA) ----------

def test_handler_completes_well_under_3_seconds(
    reset_clients, make_request_with_signature, rtms_started_payload,
):
    webhook, request = make_request_with_signature(
        "meeting.rtms_started", rtms_started_payload
    )
    start = time.monotonic()
    main.process_webhook(webhook, request, MockResponse())
    assert time.monotonic() - start < 1.0  # generous; spec says 3s
