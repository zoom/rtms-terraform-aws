"""AC#1 (URL validation CRC) and AC#2 (HMAC signature) — pure functions."""

from __future__ import annotations

import hashlib
import hmac
import time

from main import compute_validation_response, verify_signature

from .conftest import WEBHOOK_SECRET, sign_webhook


# ---------- AC #1 — endpoint.url_validation CRC handshake ----------

def test_crc_response_uses_hmac_sha256_of_plain_token_with_secret():
    plain_token = "qgg8vlvZRS6UYooatFL8Aw"
    expected = hmac.new(
        WEBHOOK_SECRET.encode(), plain_token.encode(), hashlib.sha256
    ).hexdigest()

    response = compute_validation_response(plain_token)

    assert response["plainToken"] == plain_token
    assert response["encryptedToken"] == expected


def test_crc_response_is_deterministic_for_same_input():
    a = compute_validation_response("deterministic-token")
    b = compute_validation_response("deterministic-token")
    assert a == b


def test_crc_response_differs_for_different_secrets():
    a = compute_validation_response("shared-token", secret="secret-A")
    b = compute_validation_response("shared-token", secret="secret-B")
    assert a["encryptedToken"] != b["encryptedToken"]


# ---------- AC #2 — webhook HMAC signature verification ----------

def test_valid_signature_is_accepted():
    body = b'{"event":"meeting.rtms_started"}'
    ts = str(int(time.time()))
    sig = sign_webhook(body, ts)
    assert verify_signature(body, ts, sig) is True


def test_invalid_signature_is_rejected():
    body = b'{"event":"meeting.rtms_started"}'
    ts = str(int(time.time()))
    assert verify_signature(body, ts, "v0=tampered") is False


def test_missing_signature_is_rejected():
    assert verify_signature(b'{"x":1}', str(int(time.time())), "") is False


def test_missing_timestamp_is_rejected():
    body = b'{"x":1}'
    sig = sign_webhook(body, "1700000000")
    assert verify_signature(body, "", sig) is False


def test_signature_for_different_timestamp_is_rejected():
    body = b'{"x":1}'
    sig = sign_webhook(body, "1700000000")
    assert verify_signature(body, "1700000999", sig) is False


def test_signature_for_different_body_is_rejected():
    ts = str(int(time.time()))
    sig = sign_webhook(b'{"original":true}', ts)
    assert verify_signature(b'{"tampered":true}', ts, sig) is False


def test_signature_for_different_secret_is_rejected():
    body = b'{"x":1}'
    ts = str(int(time.time()))
    sig = sign_webhook(body, ts, secret="other-secret")
    assert verify_signature(body, ts, sig) is False


def test_signature_format_is_v0_prefixed():
    body = b'{"x":1}'
    sig = sign_webhook(body, str(int(time.time())))
    assert sig.startswith("v0=")
    assert len(sig) == len("v0=") + 64  # SHA-256 hex


# ---------- canonical-body path — JSON.stringify-compatible HMAC -----------

def test_canonical_body_matches_javascript_json_stringify():
    """Zoom signs JSON.stringify(body). _canonical_body must produce
    byte-identical output: no whitespace, ensure_ascii=False."""
    from main import _canonical_body

    payload = {
        "event": "meeting.rtms_started",
        "payload": {"meeting_uuid": "abc==", "is_original_host": True},
        "event_ts": 1779296148798,
    }
    # What JSON.stringify({event:...,payload:{...},event_ts:...}) produces:
    expected = (
        b'{"event":"meeting.rtms_started",'
        b'"payload":{"meeting_uuid":"abc==","is_original_host":true},'
        b'"event_ts":1779296148798}'
    )
    assert _canonical_body(payload) == expected


def test_canonical_body_omits_whitespace_around_separators():
    """Python's json.dumps defaults insert ' ' after ':' and ','. Zoom doesn't."""
    from main import _canonical_body
    body = _canonical_body({"a": 1, "b": 2})
    assert b" " not in body  # no whitespace anywhere


def test_canonical_body_preserves_non_ascii_unicode():
    """JSON.stringify keeps unicode literals; default json.dumps escapes them."""
    from main import _canonical_body
    body = _canonical_body({"name": "café"})
    assert body == '{"name":"café"}'.encode("utf-8")


def test_full_signature_round_trip_against_canonical_body():
    """Sign the canonical body, then verify it back — full HMAC cycle."""
    from main import _canonical_body

    parsed_webhook = {
        "event": "meeting.rtms_started",
        "payload": {"rtms_stream_id": "abc"},
    }
    canonical = _canonical_body(parsed_webhook)
    ts        = str(int(time.time()))
    signature = sign_webhook(canonical, ts)

    assert verify_signature(canonical, ts, signature) is True


def test_signature_rejected_when_payload_was_tampered():
    """If anything in the payload differs from what was signed, HMAC fails."""
    from main import _canonical_body

    signed_payload = {"event": "meeting.rtms_started"}
    tampered       = {"event": "meeting.rtms_stopped"}
    ts             = str(int(time.time()))
    sig            = sign_webhook(_canonical_body(signed_payload), ts)

    assert verify_signature(_canonical_body(tampered), ts, sig) is False
