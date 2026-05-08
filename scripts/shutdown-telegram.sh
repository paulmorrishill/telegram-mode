#!/usr/bin/env bash
# Global kill switch for telegram-mode. Writes <skill-dir>/state/shutdown.flag.
#
# Active ask-user.sh processes detect on next poll, exit code 3, and emit
# "__TELEGRAM_SHUTDOWN__: <reason>" on stdout. The router daemon sees the
# flag and exits. New ask-user.sh invocations refuse to start while the flag
# is present.
#
# Usage:
#   shutdown-telegram.sh [--reason "..."] [--notify]    # write flag
#   shutdown-telegram.sh --reset                        # remove flag
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SKILL_DIR/state/.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

STATE_DIR="$SKILL_DIR/state"
mkdir -p "$STATE_DIR"
FLAG_PATH="$STATE_DIR/shutdown.flag"

REASON='Closed by user. Do not re-initiate, do not continue the conversation.'
NOTIFY=0
RESET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --reason)    REASON="$2"; shift ;;
        --reason=*)  REASON="${1#*=}" ;;
        --notify)    NOTIFY=1 ;;
        --reset)     RESET=1 ;;
        -h|--help)
            sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ "$RESET" = "1" ]; then
    if [ -f "$FLAG_PATH" ]; then
        rm -f "$FLAG_PATH"
        echo "shutdown flag removed: $FLAG_PATH"
    else
        echo "no shutdown flag present at $FLAG_PATH"
    fi
    exit 0
fi

PAYLOAD="$(jq -nc --arg r "$REASON" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson pid "$$" \
    '{reason:$r, created_at:$ts, created_by_pid:$pid}')"
TMP="$FLAG_PATH.tmp.$$"
printf '%s' "$PAYLOAD" > "$TMP"
mv -f "$TMP" "$FLAG_PATH"
echo "shutdown flag written: $FLAG_PATH"

if [ "$NOTIFY" = "1" ]; then
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        BODY="$(jq -nc --arg c "$TELEGRAM_CHAT_ID" --arg t "📟 telegram-mode SHUTDOWN — $REASON" '{chat_id:$c, text:$t}')"
        curl -fsS --max-time 15 -X POST \
            -H 'Content-Type: application/json' \
            --data "$BODY" \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" >/dev/null 2>&1 \
            && echo "shutdown notification sent." \
            || echo "Telegram notify failed (continuing)." >&2
    else
        echo "--notify requested but TELEGRAM_* not set; skipping." >&2
    fi
fi
exit 0
