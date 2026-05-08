#!/usr/bin/env bash
# Fire-and-forget Telegram send. Prints message_id on stdout on success.
#
# Usage:
#   send-telegram.sh --text "..."       [--markdown] [--silent]
#   send-telegram.sh -t "..."           [-m]         [-s]
#
# Reads TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID (env or <skill-dir>/state/.env).
# Exit codes: 0 ok; 1 transport/API error; 2 setup error.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SKILL_DIR/state/.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

TEXT=""
MARKDOWN=0
SILENT=0

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--text)      TEXT="$2"; shift ;;
        --text=*)       TEXT="${1#*=}" ;;
        -m|--markdown)  MARKDOWN=1 ;;
        -s|--silent)    SILENT=1 ;;
        -h|--help)
            sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -z "$TEXT" ]; then echo "--text required" >&2; exit 2; fi
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then echo "TELEGRAM_BOT_TOKEN not set" >&2; exit 2; fi
if [ -z "${TELEGRAM_CHAT_ID:-}" ];  then echo "TELEGRAM_CHAT_ID not set"  >&2; exit 2; fi

# Translate literal "\n" / "\t" / "\r" / "\r\n" sequences into real whitespace
# (callers sometimes pass two-char escapes that their tool wrapper didn't
# interpret).
TEXT="$(printf '%s' "$TEXT" | python3 -c '
import sys
s = sys.stdin.read()
s = s.replace("\\r\\n", "\r\n").replace("\\n", "\n").replace("\\r", "\r").replace("\\t", "\t")
sys.stdout.write(s)
')"

PAYLOAD="$(jq -nc \
    --arg c "$TELEGRAM_CHAT_ID" \
    --arg t "$TEXT" \
    --argjson md "$MARKDOWN" \
    --argjson silent "$SILENT" \
    '{chat_id:$c, text:$t}
     + (if $md == 1     then {parse_mode:"MarkdownV2"} else {} end)
     + (if $silent == 1 then {disable_notification:true} else {} end)')"

RESP="$(curl -fsS --max-time 30 -X POST \
    -H 'Content-Type: application/json' \
    --data "$PAYLOAD" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" 2>&1)" || {
    echo "Telegram send failed: $RESP" >&2
    exit 1
}

OK="$(printf '%s' "$RESP" | jq -r '.ok')"
if [ "$OK" != "true" ]; then
    echo "Telegram API ok=false: $RESP" >&2
    exit 1
fi
printf '%s' "$RESP" | jq -r '.result.message_id'
exit 0
