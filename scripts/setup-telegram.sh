#!/usr/bin/env bash
# One-time setup wizard for telegram-mode (macOS / Linux).
#
# Walks through:
#   1. Prompt for bot token (osascript hidden-answer dialog on macOS;
#      terminal `read -s` fallback elsewhere).
#   2. Validate via Telegram getMe.
#   3. Drain pending updates so we don't pick up stale messages.
#   4. Prompt user to send the bot a first message (osascript info dialog,
#      or terminal echo).
#   5. Long-poll getUpdates to capture chat_id.
#   6. Persist TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID to <skill-dir>/state/.env
#      (sourced by all other scripts; no shell rc edits needed).
#   7. Send confirmation message.
#
# Exit codes: 0 ok; 1 cancelled / no message; 2 unexpected error.
set -uo pipefail

POLL_TIMEOUT="${POLL_TIMEOUT:-120}"
NO_PERSIST="${NO_PERSIST:-0}"
USE_GUI="auto"   # auto | yes | no

while [ $# -gt 0 ]; do
    case "$1" in
        --no-persist)         NO_PERSIST=1 ;;
        --poll-timeout)       POLL_TIMEOUT="$2"; shift ;;
        --poll-timeout=*)     POLL_TIMEOUT="${1#*=}" ;;
        --no-gui)             USE_GUI="no" ;;
        --gui)                USE_GUI="yes" ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [--no-persist] [--poll-timeout <seconds>] [--no-gui|--gui]

  --no-persist          Validate + capture but don't write state/.env.
  --poll-timeout N      Seconds to wait for first message (default 120).
  --no-gui              Force terminal prompts even if osascript is available.
  --gui                 Force GUI dialogs (errors out if osascript missing).
EOF
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required tool missing: $cmd" >&2
        exit 2
    fi
done

# Decide GUI mode.
HAVE_OSASCRIPT=0
command -v osascript >/dev/null 2>&1 && HAVE_OSASCRIPT=1
case "$USE_GUI" in
    auto) GUI=$HAVE_OSASCRIPT ;;
    yes)  if [ $HAVE_OSASCRIPT -eq 0 ]; then echo "--gui requested but osascript not available" >&2; exit 2; fi; GUI=1 ;;
    no)   GUI=0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$SKILL_DIR/state"
ENV_FILE="$STATE_DIR/.env"
mkdir -p "$STATE_DIR"

# Escape a string for embedding inside an AppleScript double-quoted literal.
# Backslash and double-quote need escaping; newlines stay as real LF (AS handles them).
as_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Hidden-answer text input. Echoes entered text on stdout; empty stdout = cancel.
gui_prompt_secret() {
    local prompt="$1" title="$2"
    local p t
    p="$(as_escape "$prompt")"
    t="$(as_escape "$title")"
    osascript <<EOF 2>/dev/null
try
    set r to display dialog "$p" with title "$t" default answer "" with hidden answer buttons {"Cancel","OK"} default button "OK" cancel button "Cancel"
    return text returned of r
on error
    return ""
end try
EOF
}

gui_info() {
    local msg="$1" title="$2"
    local m t
    m="$(as_escape "$msg")"
    t="$(as_escape "$title")"
    osascript <<EOF >/dev/null 2>&1
display dialog "$m" with title "$t" buttons {"OK"} default button "OK"
EOF
}

gui_error() {
    local msg="$1" title="$2"
    local m t
    m="$(as_escape "$msg")"
    t="$(as_escape "$title")"
    osascript <<EOF >/dev/null 2>&1
display dialog "$m" with title "$t" buttons {"OK"} default button "OK" with icon stop
EOF
}

gui_yesno() {
    local msg="$1" title="$2"
    local m t result
    m="$(as_escape "$msg")"
    t="$(as_escape "$title")"
    result="$(osascript <<EOF 2>/dev/null
try
    set r to display dialog "$m" with title "$t" buttons {"No","Yes"} default button "Yes" cancel button "No" with icon caution
    return "yes"
on error
    return "no"
end try
EOF
)"
    [ "$result" = "yes" ]
}

prompt_secret() {
    local prompt="$1" title="$2" var
    if [ "$GUI" = "1" ]; then
        gui_prompt_secret "$prompt" "$title"
    else
        printf '%s\n(input hidden, empty cancels): ' "$prompt" >&2
        read -r -s var
        echo >&2
        printf '%s' "$var"
    fi
}

show_info() {
    if [ "$GUI" = "1" ]; then
        gui_info "$1" "$2"
    else
        printf '\n%s\n' "$1" >&2
    fi
}

show_error() {
    if [ "$GUI" = "1" ]; then
        gui_error "$1" "$2"
    else
        printf '\nERROR: %s\n' "$1" >&2
    fi
}

ask_yesno() {
    if [ "$GUI" = "1" ]; then
        gui_yesno "$1" "$2"
    else
        local ans
        printf '%s [y/N] ' "$1" >&2
        read -r ans
        case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
    fi
}

if [ "$GUI" != "1" ]; then
    echo "telegram-mode setup wizard"
    echo "=========================="
    echo
fi

TITLE="telegram-mode setup"

# 1. Token prompt + validation loop.
TOKEN=""
BOT_USERNAME=""
while true; do
    ENTERED="$(prompt_secret "Paste your Telegram bot token from @BotFather.

Format: 1234567890:AA...

Click Cancel (or send empty) to abort." "$TITLE")"
    if [ -z "${ENTERED:-}" ]; then
        show_info "Setup cancelled. No changes made." "$TITLE"
        exit 1
    fi
    TOKEN="$(printf '%s' "$ENTERED" | tr -d '[:space:]')"

    if ! RESP="$(curl -fsS --max-time 15 "https://api.telegram.org/bot${TOKEN}/getMe" 2>&1)"; then
        if ask_yesno "Telegram rejected that token:

$RESP

Try again?" "$TITLE"; then continue; else exit 1; fi
    fi
    OK="$(printf '%s' "$RESP" | jq -r '.ok')"
    if [ "$OK" != "true" ]; then
        if ask_yesno "API returned ok=false:

$RESP

Try again?" "$TITLE"; then continue; else exit 1; fi
    fi
    BOT_USERNAME="$(printf '%s' "$RESP" | jq -r '.result.username')"
    break
done

# 2. Drain pending updates so we don't pick up stale ones.
DRAIN="$(curl -fsS --max-time 15 "https://api.telegram.org/bot${TOKEN}/getUpdates?timeout=0&limit=100" 2>&1)" || {
    show_error "Could not query Telegram API:

$DRAIN" "$TITLE"
    exit 2
}
OFFSET="$(printf '%s' "$DRAIN" | jq -r '[.result[].update_id] | (max // -1) + 1')"
if [ "$OFFSET" -gt 0 ]; then
    curl -fsS --max-time 15 "https://api.telegram.org/bot${TOKEN}/getUpdates?offset=${OFFSET}&timeout=0&limit=1" >/dev/null 2>&1 || true
fi

# 3. Ask user to send first message.
show_info "Bot validated: @${BOT_USERNAME}

Now:
  1. Open Telegram.
  2. Search for @${BOT_USERNAME} (or open the chat with your bot).
  3. Press START — or just send any message ('hi' is fine).

Click OK after you've sent at least one message.
Polling will run for up to ${POLL_TIMEOUT} seconds." "$TITLE"

# 4. Long-poll until we see a message.
[ "$GUI" != "1" ] && echo "Polling for first message (up to ${POLL_TIMEOUT}s)..." >&2
CHAT_ID=""
START_TS=$(date +%s)
while :; do
    NOW=$(date +%s)
    if [ $((NOW - START_TS)) -ge "$POLL_TIMEOUT" ]; then break; fi
    R="$(curl -fsS --max-time 25 "https://api.telegram.org/bot${TOKEN}/getUpdates?offset=${OFFSET}&timeout=15&limit=10" 2>/dev/null)" || { sleep 2; continue; }
    NEW_OFFSET="$(printf '%s' "$R" | jq -r --argjson cur "$OFFSET" '[.result[].update_id] | (max // ($cur - 1)) + 1')"
    if [ "$NEW_OFFSET" -gt "$OFFSET" ]; then OFFSET="$NEW_OFFSET"; fi
    CHAT_ID="$(printf '%s' "$R" | jq -r '
        [ .result[] | (.message // .edited_message) | select(. != null) | .chat.id ]
        | map(select(. != null))
        | .[0] // empty
    ')"
    if [ -n "$CHAT_ID" ]; then break; fi
done

if [ -z "$CHAT_ID" ]; then
    show_error "Didn't see a message in ${POLL_TIMEOUT} seconds.

Make sure you sent something to @${BOT_USERNAME}, then re-run this script." "$TITLE"
    exit 1
fi

# 5. Persist (or display).
if [ "$NO_PERSIST" = "1" ]; then
    show_info "Setup complete (--no-persist).

  Bot:     @${BOT_USERNAME}
  Chat ID: ${CHAT_ID}

To enable the skill, write ${ENV_FILE} yourself:

  export TELEGRAM_BOT_TOKEN=<paste-token>
  export TELEGRAM_CHAT_ID=${CHAT_ID}" "$TITLE"
    exit 0
fi

umask 077
{
    printf '# telegram-mode skill — generated by setup-telegram.sh on %s\n' "$(date)"
    printf 'export TELEGRAM_BOT_TOKEN=%q\n' "$TOKEN"
    printf 'export TELEGRAM_CHAT_ID=%q\n'   "$CHAT_ID"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

# 6. Send confirmation message.
curl -fsS --max-time 15 -X POST \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg c "$CHAT_ID" --arg t "✅ telegram-mode skill setup complete. Say 'telegram mode' to Claude in any session." '{chat_id:$c, text:$t}')" \
    "https://api.telegram.org/bot${TOKEN}/sendMessage" >/dev/null 2>&1 || true

show_info "Setup complete.

  Bot:     @${BOT_USERNAME}
  Chat ID: ${CHAT_ID}
  Config:  ${ENV_FILE}  (mode 600; sourced by all skill scripts)

You can now say \"telegram mode\" to Claude in any session." "$TITLE"
exit 0
