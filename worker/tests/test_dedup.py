"""AC#3 — duplicate webhooks for the same rtms_stream_id are idempotent."""

from __future__ import annotations

import main

from .conftest import MockResponse


def test_first_started_webhook_triggers_join(reset_clients, rtms_started_payload):
    main.start_meeting(rtms_started_payload)
    assert len(reset_clients.instances) == 1


def test_duplicate_started_webhook_does_not_join_twice(
    reset_clients, rtms_started_payload,
):
    main.start_meeting(rtms_started_payload)
    main.start_meeting(rtms_started_payload)
    assert len(reset_clients.instances) == 1


def test_different_stream_ids_each_trigger_join(reset_clients):
    main.start_meeting({
        "meeting_uuid": "m1", "rtms_stream_id": "s1",
        "server_urls": "wss://x", "signature": "sig-1",
    })
    main.start_meeting({
        "meeting_uuid": "m2", "rtms_stream_id": "s2",
        "server_urls": "wss://x", "signature": "sig-2",
    })
    assert len(reset_clients.instances) == 2


def test_after_stop_same_stream_id_can_rejoin(
    reset_clients, rtms_started_payload, rtms_stopped_payload,
):
    main.start_meeting(rtms_started_payload)
    main.stop_meeting(rtms_stopped_payload)
    main.start_meeting(rtms_started_payload)
    assert len(reset_clients.instances) == 2


def test_missing_stream_id_is_skipped(reset_clients):
    main.start_meeting({"meeting_uuid": "m1"})  # no rtms_stream_id
    assert len(reset_clients.instances) == 0
