"""AC#10 — structured (JSON) log output, including `extra=` field passthrough."""

from __future__ import annotations

import json
import logging

import main


def _format(level: int, msg: str, **extra) -> str:
    """Render a record through main.JsonFormatter."""
    formatter = main.JsonFormatter()
    record = logging.LogRecord(
        name="rtms-worker", level=level, pathname="", lineno=0,
        msg=msg, args=(), exc_info=None,
    )
    for k, v in extra.items():
        setattr(record, k, v)
    return formatter.format(record)


def test_log_output_is_valid_json():
    parsed = json.loads(_format(logging.INFO, "a test message"))
    assert parsed["msg"] == "a test message"


def test_log_includes_level_name():
    parsed = json.loads(_format(logging.WARNING, "careful"))
    assert parsed["level"] == "WARNING"


def test_log_includes_logger_name():
    parsed = json.loads(_format(logging.INFO, "named"))
    assert parsed["name"] == "rtms-worker"


def test_log_includes_iso_timestamp():
    parsed = json.loads(_format(logging.INFO, "tick"))
    assert "ts" in parsed
    assert parsed["ts"][4] == "-" and parsed["ts"][7] == "-" and parsed["ts"][10] == "T"


def test_log_passes_through_extra_fields():
    """Structured fields like request_id should land in the JSON output."""
    parsed = json.loads(_format(
        logging.INFO, "webhook arrived",
        request_id="abc123",
        stream_id="stream-x",
        meeting_uuid="mtg-y",
        event="meeting.rtms_started",
    ))
    assert parsed["request_id"]   == "abc123"
    assert parsed["stream_id"]    == "stream-x"
    assert parsed["meeting_uuid"] == "mtg-y"
    assert parsed["event"]        == "meeting.rtms_started"


def test_log_serializes_headers_dict_in_extras():
    parsed = json.loads(_format(
        logging.INFO, "with headers",
        headers={"x-zm-trackingid": "v=2.0;...", "x-zm-signature": "v0=abc"},
    ))
    assert parsed["headers"]["x-zm-trackingid"] == "v=2.0;..."


def test_log_drops_unknown_extras():
    """Only the documented EXTRA_KEYS pass through; everything else is silent."""
    parsed = json.loads(_format(
        logging.INFO, "noise",
        not_a_known_extra="should-not-appear",
    ))
    assert "not_a_known_extra" not in parsed
