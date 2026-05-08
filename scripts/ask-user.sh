#!/usr/bin/env bash
# Blocking ask-the-user helper. Sends a question to Telegram, blocks until
# the user replies (Telegram reply feature OR plain message after the
# question, with snipe-guard). Prints reply text on stdout.
#
# Multi-session safe — thin client over telegram-router.sh, the singleton
# getUpdates poller.
#
# Usage:
#   ask-user.sh --question "..." [--timeout-seconds N] [--issue-number N]
#               [--skip-telegram --reply-to-message-id ID]
#
# Exit codes: 0 = answered; 1 = timed out; 2 = setup error;
#             3 = shutdown sentinel emitted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SKILL_DIR/state/.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

QUESTION=""
REPLY_TO_MSG_ID=0
ISSUE_NUMBER=0
TIMEOUT_SECONDS=86400
SKIP_TELEGRAM=0

while [ $# -gt 0 ]; do
    case "$1" in
        -q|--question)               QUESTION="$2"; shift ;;
        --question=*)                QUESTION="${1#*=}" ;;
        --reply-to-message-id)       REPLY_TO_MSG_ID="$2"; shift ;;
        --reply-to-message-id=*)     REPLY_TO_MSG_ID="${1#*=}" ;;
        --issue-number)              ISSUE_NUMBER="$2"; shift ;;
        --issue-number=*)            ISSUE_NUMBER="${1#*=}" ;;
        --timeout-seconds)           TIMEOUT_SECONDS="$2"; shift ;;
        --timeout-seconds=*)         TIMEOUT_SECONDS="${1#*=}" ;;
        --skip-telegram)             SKIP_TELEGRAM=1 ;;
        # Compat-only flags from old PS interface (ignored):
        --repo|--repo=*)             ;;
        --responding-user|--responding-user=*) ;;
        --poll-seconds|--poll-seconds=*)       ;;
        -h|--help)
            sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -z "$QUESTION" ]; then echo "--question required" >&2; exit 2; fi
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then echo "TELEGRAM_BOT_TOKEN not set" >&2; exit 2; fi
if [ -z "${TELEGRAM_CHAT_ID:-}" ];  then echo "TELEGRAM_CHAT_ID not set"  >&2; exit 2; fi

STATE_DIR="$SKILL_DIR/state"
WANT_DIR="$STATE_DIR/want"
REPLY_DIR="$STATE_DIR/reply"
LOCK_DIR="$STATE_DIR/router.lock"
FLAG_PATH="$STATE_DIR/shutdown.flag"
ROUTER_SH="$SCRIPT_DIR/telegram-router.sh"
mkdir -p "$WANT_DIR" "$REPLY_DIR"

API_BASE="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

read_shutdown_reason() {
    [ ! -f "$FLAG_PATH" ] && return 1
    local r
    r="$(jq -r '.reason // "Shutdown flag present (no reason)."' "$FLAG_PATH" 2>/dev/null \
         || echo 'Shutdown flag present (unparseable).')"
    printf '%s' "$r"
    return 0
}

# Refuse to start if shutdown flag is present.
if reason="$(read_shutdown_reason)"; then
    printf '__TELEGRAM_SHUTDOWN__: %s\n' "$reason"
    exit 3
fi

# Translate literal escape sequences in question text.
QUESTION="$(printf '%s' "$QUESTION" | python3 -c '
import sys
s = sys.stdin.read()
s = s.replace("\\r\\n", "\r\n").replace("\\n", "\n").replace("\\r", "\r").replace("\\t", "\t")
sys.stdout.write(s)
')"

# 1. Send question (or accept caller's id).
TARGET_MSG_ID="$REPLY_TO_MSG_ID"
SENT_AT="$(date +%s)"
if [ "$SKIP_TELEGRAM" = "0" ]; then
    HEADER=""
    if [ "$ISSUE_NUMBER" -gt 0 ]; then HEADER="[issue #$ISSUE_NUMBER] "; fi
    BODY="$(jq -nc --arg c "$TELEGRAM_CHAT_ID" --arg t "${HEADER}${QUESTION}" '{chat_id:$c, text:$t}')"
    SENT="$(curl -fsS --max-time 30 -X POST \
        -H 'Content-Type: application/json' \
        --data "$BODY" \
        "${API_BASE}/sendMessage" 2>&1)" || {
        echo "Telegram sendMessage failed: $SENT" >&2
        exit 2
    }
    OK="$(printf '%s' "$SENT" | jq -r '.ok')"
    if [ "$OK" != "true" ]; then
        echo "sendMessage ok=false: $SENT" >&2
        exit 2
    fi
    TARGET_MSG_ID="$(printf '%s' "$SENT" | jq -r '.result.message_id')"
    DT="$(printf '%s' "$SENT" | jq -r '.result.date // empty')"
    [ -n "$DT" ] && SENT_AT="$DT"
elif [ "$TARGET_MSG_ID" -le 0 ]; then
    echo "--skip-telegram requires --reply-to-message-id" >&2
    exit 2
fi
printf '[ask-user] target msg_id=%s sent_at=%s\n' "$TARGET_MSG_ID" "$SENT_AT" >&2

# 2. Register .want (PID-owned) and .meta.
WANT_PATH="$WANT_DIR/$TARGET_MSG_ID"
META_PATH="${WANT_PATH}.meta"
REPLY_PATH="$REPLY_DIR/$TARGET_MSG_ID"
# Pre-clean any stale reply file from a prior orphaned attempt.
rm -f "$REPLY_PATH" 2>/dev/null || true
printf '%s\n' "$$" > "$WANT_PATH"
printf '{"sent_at":%s}' "$SENT_AT" > "$META_PATH"

cleanup() {
    rm -f "$WANT_PATH" "$META_PATH" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# 3. Ensure router is running. Spawn detached if not.
spawn_router() {
    nohup bash "$ROUTER_SH" >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

router_alive() {
    [ -d "$LOCK_DIR" ] || return 1
    local pid
    pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

if ! router_alive; then
    printf '[ask-user] spawning router...\n' >&2
    spawn_router
    sleep 0.4
fi

# 4. Wait for reply file.
START_TS=$(date +%s)
while :; do
    if [ "$TIMEOUT_SECONDS" -gt 0 ]; then
        NOW=$(date +%s)
        if [ $((NOW - START_TS)) -ge "$TIMEOUT_SECONDS" ]; then
            echo "Timed out after $TIMEOUT_SECONDS seconds waiting for reply to msg_id=$TARGET_MSG_ID" >&2
            exit 1
        fi
    fi
    if reason="$(read_shutdown_reason)"; then
        printf '__TELEGRAM_SHUTDOWN__: %s\n' "$reason"
        exit 3
    fi
    if [ -f "$REPLY_PATH" ]; then
        TEXT="$(cat "$REPLY_PATH" 2>/dev/null || true)"
        rm -f "$REPLY_PATH" 2>/dev/null || true
        printf '%s' "$TEXT"
        printf '\n'
        exit 0
    fi
    if ! router_alive; then
        spawn_router
        sleep 0.4
    fi
    sleep 0.5
done
