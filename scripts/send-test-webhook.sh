#!/usr/bin/env bash
# Layer 3 — AWS smoke harness. Sends signed test webhooks to a deployed worker.
#
# Usage:
#   WEBHOOK_URL=https://rtms.example.com bash scripts/send-test-webhook.sh validation
#   WEBHOOK_URL=https://rtms.example.com bash scripts/send-test-webhook.sh invalid
#   WEBHOOK_URL=https://rtms.example.com bash scripts/send-test-webhook.sh started
#   WEBHOOK_URL=https://rtms.example.com bash scripts/send-test-webhook.sh stopped
#   WEBHOOK_URL=https://rtms.example.com bash scripts/send-test-webhook.sh burst 20

set -euo pipefail

: "${WEBHOOK_URL:?WEBHOOK_URL must be set (e.g. https://rtms.example.com)}"
: "${ZM_RTMS_WEBHOOK_SECRET:?ZM_RTMS_WEBHOOK_SECRET must be set}"

MODE="${1:-validation}"
COUNT="${2:-1}"

sign_body() {
  local body="$1" ts="$2"
  printf "v0=%s" "$(printf 'v0:%s:%s' "$ts" "$body" \
    | openssl dgst -sha256 -hmac "$ZM_RTMS_WEBHOOK_SECRET" -binary \
    | xxd -p -c 256)"
}

post_webhook() {
  local body="$1" ts sig
  ts="$(date +%s)"
  sig="$(sign_body "$body" "$ts")"

  curl -sS -o /tmp/rtms-webhook-resp.txt -w "HTTP %{http_code}\n" \
    -H 'Content-Type: application/json' \
    -H "x-zm-signature: $sig" \
    -H "x-zm-request-timestamp: $ts" \
    --data-raw "$body" \
    "$WEBHOOK_URL/webhook"
  echo "  response: $(cat /tmp/rtms-webhook-resp.txt)"
}

case "$MODE" in
  validation)
    # endpoint.url_validation — does NOT require x-zm-signature
    body='{"event":"endpoint.url_validation","payload":{"plainToken":"smoke-test-token"}}'
    echo "POST /webhook (endpoint.url_validation)"
    curl -sS -o /tmp/rtms-webhook-resp.txt -w "HTTP %{http_code}\n" \
      -H 'Content-Type: application/json' \
      --data-raw "$body" "$WEBHOOK_URL/webhook"
    echo "  response: $(cat /tmp/rtms-webhook-resp.txt)"
    ;;

  invalid)
    # Invalid signature → expect 401
    body='{"event":"meeting.rtms_started","payload":{}}'
    ts="$(date +%s)"
    echo "POST /webhook (invalid signature)"
    curl -sS -o /tmp/rtms-webhook-resp.txt -w "HTTP %{http_code}\n" \
      -H 'Content-Type: application/json' \
      -H 'x-zm-signature: v0=deadbeef' \
      -H "x-zm-request-timestamp: $ts" \
      --data-raw "$body" "$WEBHOOK_URL/webhook"
    echo "  response: $(cat /tmp/rtms-webhook-resp.txt)"
    ;;

  started)
    body='{"event":"meeting.rtms_started","payload":{"meeting_uuid":"smoke-uuid","rtms_stream_id":"smoke-stream","server_urls":"wss://rtms.example.com","signature":"smoke-sig"}}'
    echo "POST /webhook (meeting.rtms_started)"
    post_webhook "$body"
    ;;

  stopped)
    body='{"event":"meeting.rtms_stopped","payload":{"meeting_uuid":"smoke-uuid","rtms_stream_id":"smoke-stream"}}'
    echo "POST /webhook (meeting.rtms_stopped)"
    post_webhook "$body"
    ;;

  burst)
    echo "POSTing $COUNT meeting.rtms_started webhooks…"
    for i in $(seq 1 "$COUNT"); do
      body="$(printf '{"event":"meeting.rtms_started","payload":{"meeting_uuid":"burst-%s","rtms_stream_id":"burst-stream-%s","server_urls":"wss://rtms.example.com","signature":"burst-sig"}}' "$i" "$i")"
      post_webhook "$body" &
    done
    wait
    ;;

  *)
    echo "unknown mode: $MODE" >&2
    echo "modes: validation | invalid | started | stopped | burst <count>" >&2
    exit 2
    ;;
esac
