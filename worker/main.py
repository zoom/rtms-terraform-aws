"""
RTMS Cloud Worker — minimal demo.

Same shape as rtms-quickstart-py, with three demo-relevant additions:

  1. rtms.EventLoopPool — one container handles many concurrent meetings
  2. ThreadPoolExecutor for callbacks — transcript-to-S3 uploads never block
     the SDK poll loop
  3. Reconnection handling per Zoom's three RTMS failover scenarios
     (https://developers.zoom.us/docs/rtms/meetings/work-with-streams/#failover-and-reconnection):

       Scenario 1 — RTMS server failure: a *new* meeting.rtms_started arrives
         for an existing stream_id with fresh server_urls. Tear down old
         client, rejoin with new payload.

       Scenario 2 — signal connection down: meeting.rtms_interrupted webhook
         arrives. Tear down + rejoin with the webhook's fresh credentials.

       Scenario 3 — media connection down only: SDK fires
         on_media_connection_interrupted while signaling is still alive.
         Schedule re-join via stored payload with exponential backoff.
"""

import hashlib
import hmac
import json
import logging
import os
import signal
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

# Load .env (or .env.development) for local dev. Searches the script's dir
# (worker/) first, then the project root. Skipped under pytest so tests
# don't pick up the developer's real credentials from .env.development.
if "pytest" not in sys.modules:
    try:
        from pathlib import Path
        from dotenv import load_dotenv
        _here = Path(__file__).resolve().parent
        for _dir in (_here, _here.parent):
            if (_dir / ".env").exists():
                load_dotenv(_dir / ".env")
            if (_dir / ".env.development").exists():
                load_dotenv(_dir / ".env.development", override=True)
    except ImportError:
        pass

import rtms


# ─── ALB health-check shim ────────────────────────────────────────────────
# ALB target group health checks send `GET /`. The SDK's WebhookHandler
# (rtms/src/rtms/__init__.py:295) only implements do_POST → Python's
# BaseHTTPRequestHandler default fires `501 Not Implemented` for GET. ALB
# target group matchers are hard-capped at 200-499, so 501 fails health
# checks and the ALB returns 503 to every caller.
#
# Workaround: subclass and add do_GET that returns 200. Tracked upstream as
# DEVS-X9 in the RTMS SDK v1.2 plan — once the SDK ships do_GET (or 405)
# natively, delete this class and revert to rtms.WebhookHandler directly.
class _AlbHealthCheckHandler(rtms.WebhookHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

rtms.WebhookHandler = _AlbHealthCheckHandler
# ──────────────────────────────────────────────────────────────────────────


def _env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None:
        sys.stderr.write(f"FATAL: env var {name} is required\n")
        sys.exit(1)
    return value


# --- config from env ------------------------------------------------------
WEBHOOK_SECRET     = _env("ZM_RTMS_WEBHOOK_SECRET")
TRANSCRIPT_BACKEND = _env("TRANSCRIPT_BACKEND", "s3").lower()
LOCAL_DIR          = _env("LOCAL_TRANSCRIPT_DIR", "./transcripts")
AWS_REGION         = _env("AWS_REGION", "us-east-1")
EVENTLOOP_THREADS  = int(_env("EVENTLOOP_THREADS", "2"))
EXECUTOR_WORKERS   = int(_env("CALLBACK_EXECUTOR_WORKERS", "16"))

TRANSCRIPT_BUCKET  = (
    _env("TRANSCRIPT_BUCKET") if TRANSCRIPT_BACKEND == "s3"
    else os.environ.get("TRANSCRIPT_BUCKET", "")
)

# Reconnection tuning
RECONNECT_MAX_ATTEMPTS = int(_env("RECONNECT_MAX_ATTEMPTS", "5"))
RECONNECT_BACKOFF_BASE = int(_env("RECONNECT_BACKOFF_BASE_SEC", "3"))
RECONNECT_BACKOFF_CAP  = int(_env("RECONNECT_BACKOFF_CAP_SEC", "30"))


# --- structured JSON logger with `extra=` field passthrough ---------------

class JsonFormatter(logging.Formatter):
    """JSON output that picks up keys from `log.info(..., extra={...})`."""

    EXTRA_KEYS = (
        "request_id", "stream_id", "meeting_uuid", "event",
        "tracking_id", "subscription_id", "app_id",
        "action", "status", "remote_addr", "user_agent",
        "sig_present", "sig_valid",
        "headers", "payload",
    )

    def format(self, record):
        out = {
            "ts":    self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "level": record.levelname,
            "name":  record.name,
            "msg":   record.getMessage(),
        }
        for key in self.EXTRA_KEYS:
            if hasattr(record, key):
                out[key] = getattr(record, key)
        if record.exc_info:
            out["exc"] = self.formatException(record.exc_info)
        return json.dumps(out, default=str)


_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(JsonFormatter())
logging.basicConfig(
    level=_env("LOG_LEVEL", "INFO").upper(),
    handlers=[_handler],
    force=True,
)
for _noisy in ("botocore", "boto3", "urllib3", "s3transfer"):
    logging.getLogger(_noisy).setLevel(logging.WARNING)
log = logging.getLogger("rtms-worker")

# Convenience: LOG_FORMAT constant kept for any callers/tests referencing it
LOG_FORMAT = "json"  # not used at runtime now — formatter is class-based


# --- shared resources -----------------------------------------------------
if TRANSCRIPT_BACKEND == "s3":
    import boto3
    s3 = boto3.client("s3", region_name=AWS_REGION)
else:
    s3 = None
    os.makedirs(LOCAL_DIR, exist_ok=True)

pool     = rtms.EventLoopPool(threads=EVENTLOOP_THREADS)
executor = ThreadPoolExecutor(max_workers=EXECUTOR_WORKERS)

clients:           dict[str, rtms.Client] = {}
stream_payloads:   dict[str, dict]        = {}
reconnect_attempt: dict[str, int]         = {}


# --- webhook validation helpers ------------------------------------------

def _canonical_body(parsed_payload: dict) -> bytes:
    """Reproduce JavaScript's JSON.stringify(parsed_body) so HMAC matches.

    Per https://developers.zoom.us/docs/api/webhooks/#verify-webhook-events
    Zoom signs `JSON.stringify(request.body)` — i.e., the parsed body re-
    stringified in canonical JavaScript form, NOT the raw HTTP bytes.

    JavaScript's JSON.stringify:
      - No whitespace between separators           (Python: separators=(",", ":"))
      - Non-ASCII chars stay as literals            (Python: ensure_ascii=False)
      - Preserves insertion order of object keys    (Python dicts do this since 3.7)

    Together these make json.dumps output byte-identical to JSON.stringify."""
    return json.dumps(
        parsed_payload, separators=(",", ":"), ensure_ascii=False,
    ).encode("utf-8")


def verify_signature(body: bytes, timestamp: str, signature: str,
                     secret: str = WEBHOOK_SECRET) -> bool:
    if not (timestamp and signature):
        return False
    msg      = b"v0:" + timestamp.encode() + b":" + body
    expected = "v0=" + hmac.new(secret.encode(), msg, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


def compute_validation_response(plain_token: str,
                                secret: str = WEBHOOK_SECRET) -> dict:
    encrypted = hmac.new(secret.encode(), plain_token.encode(),
                         hashlib.sha256).hexdigest()
    return {"plainToken": plain_token, "encryptedToken": encrypted}


def _zm_headers(request) -> dict:
    """Pull every x-zm-* header off the request, normalizing to lowercase
    keys (http.server's BaseHTTPRequestHandler returns title-case like
    'X-Zm-Signature' which makes case-sensitive lookups fragile)."""
    if request is None:
        return {}
    headers = getattr(request, "headers", None) or {}
    try:
        items = list(headers.items())
    except AttributeError:
        return {}
    return {k.lower(): v for k, v in items if str(k).lower().startswith("x-zm-")}


# --- transcript -> S3 or local file --------------------------------------

def upload_transcript(meeting_uuid: str, record: dict) -> str:
    body = (json.dumps(record) + "\n").encode("utf-8")
    name = f"{time.time_ns()}.jsonl"

    if TRANSCRIPT_BACKEND == "local":
        out_dir = os.path.join(LOCAL_DIR, meeting_uuid)
        os.makedirs(out_dir, exist_ok=True)
        path = os.path.join(out_dir, name)
        with open(path, "wb") as fh:
            fh.write(body)
        return path

    key = f"transcripts/{meeting_uuid}/{name}"
    s3.put_object(Bucket=TRANSCRIPT_BUCKET, Key=key, Body=body,
                  ContentType="application/x-ndjson")
    return key


# --- reconnection helpers (Scenario 3 backoff) ---------------------------

def _backoff_seconds(attempt: int) -> int:
    delay = RECONNECT_BACKOFF_BASE * (2 ** max(0, attempt - 1))
    return min(delay, RECONNECT_BACKOFF_CAP)


def _schedule_media_reconnect(stream_id: str) -> None:
    attempts = reconnect_attempt.get(stream_id, 0) + 1
    if attempts > RECONNECT_MAX_ATTEMPTS:
        log.error("max reconnect attempts reached; giving up",
                  extra={"stream_id": stream_id, "action": "give_up"})
        client = clients.pop(stream_id, None)
        stream_payloads.pop(stream_id, None)
        reconnect_attempt.pop(stream_id, None)
        if client:
            try: client.leave()
            except Exception: pass
        return

    reconnect_attempt[stream_id] = attempts
    delay  = _backoff_seconds(attempts)
    pay    = stream_payloads.get(stream_id)
    client = clients.get(stream_id)
    if not (pay and client):
        log.warning("no client/payload; skipping reconnect",
                    extra={"stream_id": stream_id})
        return

    log.warning(f"scheduling media reconnect in {delay}s (attempt {attempts}/{RECONNECT_MAX_ATTEMPTS})",
                extra={"stream_id": stream_id, "action": "schedule_reconnect"})

    def _go():
        if clients.get(stream_id) is client:
            try:
                client.join(pay)
                log.info("reconnect issued",
                         extra={"stream_id": stream_id, "action": "reconnect"})
            except Exception as exc:
                log.error(f"reconnect failed: {exc}",
                          extra={"stream_id": stream_id})

    threading.Timer(delay, _go).start()


# --- meeting lifecycle ---------------------------------------------------

def start_meeting(payload: dict, *, request_id: str | None = None) -> None:
    stream_id = payload.get("rtms_stream_id")
    if not stream_id:
        log.warning("rtms_started missing stream_id",
                    extra={"request_id": request_id, "action": "skip"})
        return

    meeting_uuid = payload.get("meeting_uuid") or stream_id
    log_extra = {
        "request_id":   request_id,
        "stream_id":    stream_id,
        "meeting_uuid": meeting_uuid,
    }

    existing = clients.get(stream_id)
    if existing is not None:
        old = stream_payloads.get(stream_id, {})
        if old.get("server_urls") == payload.get("server_urls"):
            log.info("duplicate webhook for active stream — no-op",
                     extra={**log_extra, "action": "dedup"})
            return
        log.warning("server failure (new server_urls) — rejoining",
                    extra={**log_extra, "action": "scenario_1_rejoin"})
        try: existing.leave()
        except Exception: pass
        clients.pop(stream_id, None)

    client = rtms.Client(executor=executor)
    clients[stream_id]         = client
    stream_payloads[stream_id] = payload
    reconnect_attempt[stream_id] = 0

    @client.on_join_confirm
    def _(status):
        reconnect_attempt[stream_id] = 0
        log.info("on_join_confirm fired — RTMS connection live",
                 extra={**log_extra, "status": status, "action": "join_confirm"})

    @client.on_transcript_data
    def _(data, _size, ts, metadata):
        try:
            text = data.decode("utf-8", errors="replace")
            upload_transcript(meeting_uuid, {
                "ts":        ts,
                "user_id":   getattr(metadata, "userId", None),
                "user_name": getattr(metadata, "userName", None),
                "text":      text,
            })
            log.debug("transcript chunk uploaded",
                      extra={**log_extra, "action": "transcript_upload"})
        except Exception as exc:
            log.error(f"transcript upload failed: {exc}", extra=log_extra)

    @client.on_media_connection_interrupted
    def _(reason):
        log.warning(f"media connection interrupted (reason={reason})",
                    extra={**log_extra, "action": "media_interrupted"})
        _schedule_media_reconnect(stream_id)

    @client.on_leave
    def _(reason):
        clients.pop(stream_id, None)
        stream_payloads.pop(stream_id, None)
        reconnect_attempt.pop(stream_id, None)
        log.info(f"left meeting (reason={reason})",
                 extra={**log_extra, "action": "leave"})

    pool.add(client)
    client.join(payload)
    log.info("client.join() issued — awaiting on_join_confirm",
             extra={**log_extra, "action": "join_issued"})


def stop_meeting(payload: dict, *, request_id: str | None = None) -> None:
    stream_id = payload.get("rtms_stream_id")
    if not stream_id:
        return
    client = clients.pop(stream_id, None)
    stream_payloads.pop(stream_id, None)
    reconnect_attempt.pop(stream_id, None)
    log.info("rtms_stopped received",
             extra={"request_id": request_id, "stream_id": stream_id,
                    "action": "stop", "status": "had_client" if client else "no_client"})
    if client:
        try: client.leave()
        except Exception: pass


def handle_interrupted(payload: dict, *, request_id: str | None = None) -> None:
    stream_id = payload.get("rtms_stream_id")
    if not stream_id:
        return
    log.warning("rtms_interrupted — tearing down and rejoining",
                extra={"request_id": request_id, "stream_id": stream_id,
                       "action": "scenario_2_rejoin"})
    existing = clients.pop(stream_id, None)
    if existing:
        try: existing.leave()
        except Exception: pass
    stream_payloads.pop(stream_id, None)
    reconnect_attempt.pop(stream_id, None)
    start_meeting(payload, request_id=request_id)


# --- webhook handler -----------------------------------------------------

def process_webhook(webhook: dict, request=None, response=None) -> None:
    request_id  = uuid.uuid4().hex[:8]
    event       = webhook.get("event", "")
    payload     = webhook.get("payload", {})
    headers     = _zm_headers(request)
    tracking_id = headers.get("x-zm-trackingid")

    log.info("webhook arrived",
             extra={
                 "request_id":      request_id,
                 "event":           event,
                 "tracking_id":     tracking_id,
                 "stream_id":       payload.get("rtms_stream_id"),
                 "meeting_uuid":    payload.get("meeting_uuid"),
                 "headers":         headers,
             })

    # 1. CRC handshake — no signature required
    if event == "endpoint.url_validation":
        plain = payload.get("plainToken", "")
        if response is not None:
            response.send(compute_validation_response(plain))
        log.info("endpoint.url_validation responded",
                 extra={"request_id": request_id, "action": "crc_response"})
        return

    # 2. HMAC signature check — Zoom signs JSON.stringify(body), see
    #    _canonical_body for how we reproduce that in Python.
    sig_valid = None
    if request is not None and response is not None:
        ts  = headers.get("x-zm-request-timestamp", "")
        sig = headers.get("x-zm-signature", "")
        sig_valid = verify_signature(_canonical_body(webhook), ts, sig)

        if not sig_valid:
            # Plain WARN — never includes secret material or the body. Safe to
            # leave on at INFO/WARN in production because attacker probes also
            # land here and we don't want to echo back forged payloads.
            log.warning("signature invalid — rejecting with 401",
                        extra={"request_id":  request_id,
                               "sig_present": bool(sig),
                               "sig_valid":   False,
                               "action":      "reject_401"})

            # Diagnostic dump (computed sig, body, secret length+prefix/suffix)
            # is gated to DEBUG. Only enable locally when chasing a real bug.
            # Never enable in production — attacker probes hit this path and
            # logged details would echo their forged payloads back.
            if log.isEnabledFor(logging.DEBUG):
                canonical   = _canonical_body(webhook)
                signing_msg = b"v0:" + ts.encode() + b":" + canonical
                computed    = "v0=" + hmac.new(
                    WEBHOOK_SECRET.encode(), signing_msg, hashlib.sha256,
                ).hexdigest()
                secret_hint = (
                    f"len={len(WEBHOOK_SECRET)} "
                    f"prefix={WEBHOOK_SECRET[:2]!r} suffix={WEBHOOK_SECRET[-2:]!r}"
                    if WEBHOOK_SECRET else "EMPTY"
                )
                log.debug("signature mismatch diagnostic",
                          extra={"request_id": request_id,
                                 "status":     f"expected={sig} computed={computed} "
                                               f"ts={ts} body_len={len(canonical)} "
                                               f"secret({secret_hint}) "
                                               f"body={canonical.decode('utf-8', 'replace')}"})

            response.set_status(401)
            response.send({"error": "unauthorized"})
            return
        log.debug("signature valid", extra={"request_id": request_id, "sig_valid": True})
        response.send({"status": "ok"})

    # 3. Route the event
    if event == "meeting.rtms_started":
        start_meeting(payload, request_id=request_id)
    elif event == "meeting.rtms_stopped":
        stop_meeting(payload, request_id=request_id)
    elif event == "meeting.rtms_interrupted":
        handle_interrupted(payload, request_id=request_id)
    else:
        log.info("ignoring unhandled event",
                 extra={"request_id": request_id, "event": event, "action": "ignore"})


@rtms.on_webhook_event
def _webhook_handler(payload, request, response):
    process_webhook(payload, request, response)


# --- shutdown ------------------------------------------------------------

def _shutdown(*_):
    log.info(f"shutting down — leaving {len(clients)} active meetings",
             extra={"action": "shutdown"})
    for client in list(clients.values()):
        try: client.leave()
        except Exception: pass
    clients.clear()
    stream_payloads.clear()
    reconnect_attempt.clear()
    pool.stop()
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)
    log.info("starting RTMS worker",
             extra={"action": "startup",
                    "status": f"eventloop_threads={EVENTLOOP_THREADS} backend={TRANSCRIPT_BACKEND}"})
    pool.run()
