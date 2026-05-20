"""AC#5 — transcript chunks land in S3 with the documented key shape."""

from __future__ import annotations

import json
import re
import time

import main

from .conftest import TRANSCRIPT_BUCKET


def test_upload_writes_one_object_to_s3(s3_bucket):
    main.upload_transcript("mtg-1", {"text": "hello"})
    resp = s3_bucket.list_objects_v2(Bucket=TRANSCRIPT_BUCKET, Prefix="transcripts/mtg-1/")
    assert resp.get("KeyCount", 0) == 1


def test_s3_key_format_is_meeting_uuid_nanosecond_jsonl(s3_bucket):
    main.upload_transcript("mtg-abc", {"text": "x"})

    resp = s3_bucket.list_objects_v2(Bucket=TRANSCRIPT_BUCKET, Prefix="transcripts/")
    key = resp["Contents"][0]["Key"]
    m = re.match(r"transcripts/mtg-abc/(\d{16,19})\.jsonl$", key)
    assert m, f"key {key!r} did not match transcripts/<uuid>/<ns-epoch>.jsonl"
    now_ns = time.time_ns()
    assert abs(int(m.group(1)) - now_ns) < 5_000_000_000  # 5s in ns


def test_two_uploads_to_same_meeting_create_separate_keys(s3_bucket):
    """Millisecond-resolution keys must not collide on rapid bursts."""
    main.upload_transcript("mtg-1", {"text": "one"})
    main.upload_transcript("mtg-1", {"text": "two"})
    main.upload_transcript("mtg-1", {"text": "three"})

    resp = s3_bucket.list_objects_v2(Bucket=TRANSCRIPT_BUCKET, Prefix="transcripts/mtg-1/")
    assert resp.get("KeyCount", 0) == 3


def test_upload_body_is_jsonl_single_record(s3_bucket):
    record = {"ts": 1, "user_id": 42, "user_name": "Alice", "text": "hello"}
    key = main.upload_transcript("mtg-1", record)

    body = s3_bucket.get_object(Bucket=TRANSCRIPT_BUCKET, Key=key)["Body"].read().decode()
    assert body.endswith("\n")
    [line] = body.strip().splitlines()
    assert json.loads(line) == record


def test_upload_content_type_is_ndjson(s3_bucket):
    key = main.upload_transcript("mtg-1", {"text": "x"})
    obj = s3_bucket.get_object(Bucket=TRANSCRIPT_BUCKET, Key=key)
    assert obj["ContentType"] == "application/x-ndjson"


def test_upload_with_local_backend_writes_to_disk(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "TRANSCRIPT_BACKEND", "local")
    monkeypatch.setattr(main, "LOCAL_DIR", str(tmp_path))

    path = main.upload_transcript("mtg-1", {"text": "hello from disk"})

    files = list((tmp_path / "mtg-1").glob("*.jsonl"))
    assert len(files) == 1
    assert files[0].read_text().strip() == json.dumps({"text": "hello from disk"})
    assert path.endswith(".jsonl")


def test_local_backend_handles_rapid_bursts(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "TRANSCRIPT_BACKEND", "local")
    monkeypatch.setattr(main, "LOCAL_DIR", str(tmp_path))

    for i in range(5):
        main.upload_transcript("mtg-burst", {"i": i})

    files = list((tmp_path / "mtg-burst").glob("*.jsonl"))
    assert len(files) == 5


def test_two_meetings_write_to_separate_prefixes(s3_bucket):
    main.upload_transcript("mtg-A", {"text": "alice"})
    main.upload_transcript("mtg-B", {"text": "bob"})

    a = s3_bucket.list_objects_v2(Bucket=TRANSCRIPT_BUCKET, Prefix="transcripts/mtg-A/")
    b = s3_bucket.list_objects_v2(Bucket=TRANSCRIPT_BUCKET, Prefix="transcripts/mtg-B/")
    assert a["KeyCount"] == 1
    assert b["KeyCount"] == 1


def test_transcript_callback_uploads_to_s3(
    s3_bucket, reset_clients, rtms_started_payload, fake_metadata,
):
    """The on_transcript_data callback registered by start_meeting writes to S3."""
    main.start_meeting(rtms_started_payload)
    transcript_cb = reset_clients.instances[0].callbacks["transcript"]

    transcript_cb(b"hello world", 11, 1700000000, fake_metadata)

    resp = s3_bucket.list_objects_v2(
        Bucket=TRANSCRIPT_BUCKET,
        Prefix=f"transcripts/{rtms_started_payload['meeting_uuid']}/",
    )
    assert resp.get("KeyCount", 0) == 1
    key = resp["Contents"][0]["Key"]
    body = s3_bucket.get_object(Bucket=TRANSCRIPT_BUCKET, Key=key)["Body"].read().decode()
    record = json.loads(body.strip())
    assert record["text"]      == "hello world"
    assert record["user_id"]   == 42
    assert record["user_name"] == "Alice"
    assert record["ts"]        == 1700000000
