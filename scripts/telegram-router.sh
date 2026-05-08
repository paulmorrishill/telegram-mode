#!/usr/bin/env bash
# Singleton getUpdates poller for telegram-mode. Dispatches Telegram replies
# to waiting ask-user.sh clients via files.
#
# Multi-session safe: only one router runs per skill-dir, guarded by an
# atomic mkdir on state/router.lock. Liveness checked via PID file inside.
#
# Idle shutdown: exits if no active registrations for $IDLE_SECONDS.
#
# Crash recovery: each .want file contains its owner ask-user.sh PID. Files
# whose owner PID is no longer alive are treated as orphans and removed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SKILL_DIR/state/.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

IDLE_SECONDS="${IDLE_SECONDS:-90}"
POLL_SECONDS="${POLL_SECONDS:-25}"

while [ $# -gt 0 ]; do
    case "$1" in
        --idle-seconds)   IDLE_SECONDS="$2"; shift ;;
        --idle-seconds=*) IDLE_SECONDS="${1#*=}" ;;
        --poll-seconds)   POLL_SECONDS="$2"; shift ;;
        --poll-seconds=*) POLL_SECONDS="${1#*=}" ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then echo "TELEGRAM_BOT_TOKEN not set" >&2; exit 2; fi
if [ -z "${TELEGRAM_CHAT_ID:-}" ];  then echo "TELEGRAM_CHAT_ID not set"  >&2; exit 2; fi

STATE_DIR="$SKILL_DIR/state"
WANT_DIR="$STATE_DIR/want"
REPLY_DIR="$STATE_DIR/reply"
LOCK_DIR="$STATE_DIR/router.lock"
LOCK_PID="$LOCK_DIR/pid"
FLAG_PATH="$STATE_DIR/shutdown.flag"
LOG_PATH="$STATE_DIR/router.log"
mkdir -p "$WANT_DIR" "$REPLY_DIR"

API_BASE="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

log() {
    local line
    line="[$(date '+%H:%M:%S')] $*"
    printf '%s\n' "$line" >&2
    printf '%s\n' "$line" >> "$LOG_PATH" 2>/dev/null || true
}

# Acquire singleton lock with stale-pid recovery.
acquire_lock() {
    local tries=0
    while [ $tries -lt 3 ]; do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo "$$" > "$LOCK_PID"
            return 0
        fi
        local owner
        owner="$(cat "$LOCK_PID" 2>/dev/null || true)"
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
            log "another router (pid=$owner) already holds $LOCK_DIR; exiting."
            return 1
        fi
        log "stale lock (pid=$owner not alive); removing."
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        tries=$((tries + 1))
    done
    log "could not acquire lock after $tries retries; exiting."
    return 1
}

release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}

acquire_lock || exit 0
trap 'release_lock; log "router stopped."; exit 0' EXIT INT TERM

log "router started, pid=$$, statedir=$STATE_DIR"

# Drain pre-existing updates so we don't replay ancient messages.
DRAIN="$(curl -fsS --max-time 15 "${API_BASE}/getUpdates?timeout=0&limit=100" 2>/dev/null)" || {
    log "drain failed"; exit 2;
}
OFFSET="$(printf '%s' "$DRAIN" | jq -r '[.result[].update_id] | (max // -1) + 1')"
DRAIN_COUNT="$(printf '%s' "$DRAIN" | jq -r '.result | length')"
log "drained $DRAIN_COUNT prior; starting offset=$OFFSET"

idle_since=""
last_wants_sig=""

# Returns active want set on stdout, one line per active want:
#   <target_msg_id> <sent_at>
# Cleans up orphan .want files (owner PID no longer alive).
get_active_wants() {
    local f name owner sent_at meta
    for f in "$WANT_DIR"/*; do
        [ -e "$f" ] || continue
        name="${f##*/}"
        case "$name" in
            ''|*[!0-9]*) continue ;;  # skip non-numeric (e.g. .meta files)
        esac
        owner="$(head -n1 "$f" 2>/dev/null || true)"
        if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
            rm -f "$f" "${f}.meta" 2>/dev/null || true
            log "orphan .want cleaned: $name (owner=$owner)"
            continue
        fi
        sent_at=0
        meta="${f}.meta"
        if [ -f "$meta" ]; then
            sent_at="$(jq -r '.sent_at // 0' "$meta" 2>/dev/null || echo 0)"
            case "$sent_at" in ''|*[!0-9]*) sent_at=0 ;; esac
        fi
        printf '%s %s\n' "$name" "$sent_at"
    done
}

while :; do
    if [ -f "$FLAG_PATH" ]; then
        log "shutdown flag detected; exiting."
        break
    fi

    WANTS="$(get_active_wants)"
    if [ -z "$WANTS" ]; then
        sig=""
    else
        sig="$(printf '%s\n' "$WANTS" | awk '{print $1}' | sort -n | tr '\n' ',' )"
    fi
    if [ "$sig" != "$last_wants_sig" ]; then
        count=$(printf '%s\n' "$WANTS" | grep -c .)
        log "active wants: [${sig}] (count=${count})"
        last_wants_sig="$sig"
    fi

    if [ -z "$WANTS" ]; then
        if [ -z "$idle_since" ]; then idle_since=$(date +%s); fi
        now=$(date +%s)
        if [ $((now - idle_since)) -ge "$IDLE_SECONDS" ]; then
            log "idle for $IDLE_SECONDS s; exiting."
            break
        fi
        sleep 1
        continue
    fi
    idle_since=""

    # Latest active want for orphan-message routing.
    LATEST_WANT_ID=""
    LATEST_WANT_AT=0
    while IFS=' ' read -r wid wat; do
        [ -z "$wid" ] && continue
        if [ "$wat" -gt "$LATEST_WANT_AT" ]; then
            LATEST_WANT_AT="$wat"
            LATEST_WANT_ID="$wid"
        fi
    done <<EOF
$WANTS
EOF

    # Long-poll. curl --max-time set above the long-poll timeout so we don't
    # cut Telegram off prematurely.
    URL="${API_BASE}/getUpdates?offset=${OFFSET}&timeout=${POLL_SECONDS}&limit=10"
    if ! RESP="$(curl -fsS --max-time $((POLL_SECONDS + 10)) "$URL" 2>/dev/null)"; then
        log "getUpdates error"
        sleep 3
        continue
    fi
    OK="$(printf '%s' "$RESP" | jq -r '.ok // false')"
    if [ "$OK" != "true" ]; then sleep 3; continue; fi

    # Advance offset to high-water-mark of this batch.
    NEW_OFFSET="$(printf '%s' "$RESP" | jq -r --argjson cur "$OFFSET" '[.result[].update_id] | (max // ($cur - 1)) + 1')"
    if [ "$NEW_OFFSET" -gt "$OFFSET" ]; then OFFSET="$NEW_OFFSET"; fi

    # Iterate updates. Output one TSV row per relevant message:
    #   message_id <TAB> reply_to_message_id_or_empty <TAB> chat_id <TAB> date <TAB> text
    # NUL-safe: text is base64-encoded.
    UPDATES_TSV="$(printf '%s' "$RESP" | jq -r --arg chat "$TELEGRAM_CHAT_ID" '
        .result[]
        | (.message // .edited_message)
        | select(. != null)
        | select(.chat.id != null and (.chat.id|tostring) == $chat)
        | select(.text != null)
        | [
            (.message_id|tostring),
            ((.reply_to_message.message_id // "") | tostring),
            (.chat.id|tostring),
            (.date|tostring),
            (.text | @base64)
          ] | @tsv
    ')"

    if [ -n "$UPDATES_TSV" ]; then
        while IFS="$(printf '\t')" read -r MSG_ID REPLY_TO CHAT_ID MSG_DATE TEXT_B64; do
            [ -z "$MSG_ID" ] && continue
            TEXT="$(printf '%s' "$TEXT_B64" | base64 -d 2>/dev/null || true)"

            REPLY_TARGET=""
            if [ -n "$REPLY_TO" ]; then
                # Targeted reply: must match an active want.
                if printf '%s\n' "$WANTS" | awk '{print $1}' | grep -qx "$REPLY_TO"; then
                    REPLY_TARGET="$REPLY_TO"
                else
                    log "drop msg_id=$MSG_ID reply_to=$REPLY_TO (no active want)"
                    continue
                fi
            else
                # Orphan (non-reply) routing: attach to most recent active want
                # if msg.date strictly later than that want's sent_at.
                if [ -z "$LATEST_WANT_ID" ]; then
                    log "drop msg_id=$MSG_ID (no reply_to, no active wants)"
                    continue
                fi
                if [ "$MSG_DATE" -le "$LATEST_WANT_AT" ]; then
                    log "drop msg_id=$MSG_ID (no reply_to, msg.date=$MSG_DATE <= sent_at=$LATEST_WANT_AT; snipe guard)"
                    continue
                fi
                REPLY_TARGET="$LATEST_WANT_ID"
                log "orphan-route msg_id=$MSG_ID -> latest want=$REPLY_TARGET (msg.date=$MSG_DATE, sent_at=$LATEST_WANT_AT)"
            fi

            FINAL="$REPLY_DIR/$REPLY_TARGET"
            TMP="${FINAL}.tmp.$$"
            printf '%s' "$TEXT" > "$TMP" && mv -f "$TMP" "$FINAL" \
                && log "dispatched reply for target=$REPLY_TARGET (msg_id=$MSG_ID)" \
                || { log "failed to write reply file for $REPLY_TARGET"; continue; }

            # Best-effort 👀 reaction (Bot API 7.0+; silent fall-through if unsupported).
            REACT_BODY="$(jq -nc \
                --arg c "$CHAT_ID" \
                --argjson m "$MSG_ID" \
                '{chat_id:$c, message_id:$m, reaction:[{type:"emoji", emoji:"👀"}], is_big:false}')"
            curl -fsS --max-time 10 -X POST \
                -H 'Content-Type: application/json' \
                --data "$REACT_BODY" \
                "${API_BASE}/setMessageReaction" >/dev/null 2>&1 \
                || log "reaction failed for msg_id=$MSG_ID (continuing)"
        done <<EOF
$UPDATES_TSV
EOF
    fi
done
