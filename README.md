# telegram-mode

Claude Code skill that routes every clarifying question and turn-end through
Telegram instead of the terminal. Walk away from your desk; the AI keeps
working and pings your phone whenever it needs you.

## What it does

Once activated (just say "telegram mode" to Claude):

- Every question Claude would ask in the terminal is sent to a Telegram bot
  chat with you.
- Claude blocks until you reply on your phone, then continues with that
  reply as if you'd typed it at the keyboard.
- Every turn ends by waiting on Telegram too — the message stream never
  closes until you send `!quit`.
- Reply via Telegram's reply feature, or just type a fresh message in the
  chat (treated as a reply to the most recent question, with a 1-second
  snipe guard).
- Multiple Claude sessions can share the same chat — replies route by
  `reply_to_message_id`. A single router daemon handles `getUpdates` to
  avoid races.
- Acknowledgement is a 👀 reaction on your message, not a chat-spamming
  "got it" reply.

## Prerequisites

The skill ships two parallel implementations with the same contract; pick by
host OS.

| Platform              | Runtime                      | Extra tools needed                  |
| --------------------- | ---------------------------- | ----------------------------------- |
| **macOS / Linux**     | `bash` (system version is fine), `curl`, `jq`, `python3`. All preinstalled on macOS; on Linux, `apt install jq` if missing. | — |
| **Windows**           | PowerShell 7+ (`pwsh` on `PATH`). The `.ps1` scripts use PS7-only features. | — |

You also need:

- Claude Code (or any tool that reads `~/.claude/skills/<skill>/SKILL.md`)
- A Telegram bot (free, takes 60 seconds to create — see Setup below)

## Install

### macOS / Linux

```bash
git clone https://github.com/paulmorrishill/telegram-mode "$HOME/.claude/skills/telegram-mode"
chmod +x "$HOME/.claude/skills/telegram-mode/scripts/"*.sh
```

### Windows

```powershell
git clone https://github.com/paulmorrishill/telegram-mode "$env:USERPROFILE\.claude\skills\telegram-mode"
```

Claude auto-discovers skills under `~/.claude/skills/`. No `settings.json`
edit needed.

## Setup (one-time)

**1. Create a bot.** Open Telegram, message
[@BotFather](https://t.me/BotFather), send `/newbot`, follow the prompts.
BotFather replies with a bot token like `1234567890:AAH...`.

**2. Run the setup wizard.** It validates the token, asks you to send the
bot its first message, captures the chat ID, and persists both as a
skill-local config file (`<skill-dir>/state/.env`, mode 0600).

### macOS / Linux

```bash
bash "$HOME/.claude/skills/telegram-mode/scripts/setup-telegram.sh"
```

The wizard:
- Prompts for your token (input is hidden via `read -s`).
- Validates via Telegram's `getMe`.
- Asks you to open Telegram, find your bot, and send any message.
- Long-polls `getUpdates` until your message arrives, grabs the chat ID.
- Writes `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` to
  `<skill-dir>/state/.env`. All other scripts auto-source that file at
  startup, so you do **not** need to edit `~/.zshrc` / `~/.bashrc`.
- Sends a "✅ setup complete" message back to your chat.

**Manual setup (POSIX):** if you prefer, just create
`<skill-dir>/state/.env` yourself:

```bash
mkdir -p "$HOME/.claude/skills/telegram-mode/state"
cat > "$HOME/.claude/skills/telegram-mode/state/.env" <<'EOF'
export TELEGRAM_BOT_TOKEN='paste-token-here'
export TELEGRAM_CHAT_ID='paste-chat-id-here'
EOF
chmod 600 "$HOME/.claude/skills/telegram-mode/state/.env"
```

To find the chat ID without the wizard: send any message to your bot, then
visit `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser and
find `"chat":{"id": <NUMBER>, ...}`.

**Verify (POSIX):**
```bash
bash "$HOME/.claude/skills/telegram-mode/scripts/send-telegram.sh" --text "hello from skill"
```

### Windows

```powershell
pwsh -File "$env:USERPROFILE\.claude\skills\telegram-mode\scripts\Setup-Telegram.ps1"
```

The wizard pops a small dialog, validates, captures the chat ID, persists
`TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` as User-scope env vars, and pings
your chat to confirm.

**Open a NEW terminal** afterwards so the env vars load (existing terminals
won't see them).

**Manual setup (Windows):**
```powershell
[Environment]::SetEnvironmentVariable('TELEGRAM_BOT_TOKEN', '<paste-token>',   'User')
[Environment]::SetEnvironmentVariable('TELEGRAM_CHAT_ID',   '<paste-chat-id>', 'User')
```

**Verify (Windows):**
```powershell
pwsh -File "$env:USERPROFILE\.claude\skills\telegram-mode\scripts\Send-Telegram.ps1" -Text "hello from skill"
```

## Use

Open a Claude Code session and say: **"telegram mode"** (or
`/telegram-mode`, or "switch to telegram mode" — see SKILL.md for the full
trigger list).

Claude picks a short PascalCase slug for the conversation
(e.g. `FixAuthBug`), prefixes every Telegram message with that slug for
easy filtering, and starts routing. Reply on your phone using the reply
feature (or plain text — see "Reply discipline" in SKILL.md).

Send `!quit` to end the session.

## Shutdown switch

Globally close every waiting session (useful when editing the skill so
sessions don't auto-relaunch a stale router):

### macOS / Linux

```bash
bash "$HOME/.claude/skills/telegram-mode/scripts/shutdown-telegram.sh" [--reason "..."] [--notify]

# Re-enable:
bash "$HOME/.claude/skills/telegram-mode/scripts/shutdown-telegram.sh" --reset
```

### Windows

```powershell
pwsh -File "$env:USERPROFILE\.claude\skills\telegram-mode\scripts\Shutdown-Telegram.ps1" [-Reason "..."] [-Notify]

# Re-enable:
pwsh -File "$env:USERPROFILE\.claude\skills\telegram-mode\scripts\Shutdown-Telegram.ps1" -Reset
```

The flag causes every active ask-user process to exit code 3 with a
`__TELEGRAM_SHUTDOWN__: <reason>` sentinel on stdout. The skill's AI
instructions tell Claude to NOT re-enter, NOT continue, and NOT send any
further Telegram messages on seeing that sentinel.

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | Instructions Claude reads on activation |
| `scripts/setup-telegram.sh` / `Setup-Telegram.ps1` | One-time setup wizard (token → chat ID → config file or env vars) |
| `scripts/ask-user.sh` / `Ask-User.ps1` | Sends a question, blocks until reply (thin client of router) |
| `scripts/send-telegram.sh` / `Send-Telegram.ps1` | Fire-and-forget message send |
| `scripts/telegram-router.sh` / `Telegram-Router.ps1` | Singleton getUpdates daemon, dispatches replies by `reply_to_message_id` |
| `scripts/shutdown-telegram.sh` / `Shutdown-Telegram.ps1` | Global kill switch |
| `state/` | Runtime state (gitignored — contains chat content in `router.log` and credentials in `.env` on POSIX) |

## Implementation differences (POSIX vs. Windows)

The behaviour is identical; the underlying primitives differ.

| Concern | POSIX (bash) | Windows (PowerShell) |
| --- | --- | --- |
| Env var persistence | `state/.env` file (mode 0600) sourced by every script. Survives across shells without rc edits. | `[Environment]::SetEnvironmentVariable(..., 'User')`. New terminals required. |
| Singleton router lock | Atomic `mkdir state/router.lock/` directory; PID file inside; stale-PID recovery via `kill -0`. | Exclusive `OpenOrCreate` lock on `state\router.lock` file. |
| Per-waiter ownership | `.want/<id>` file content is the owner ask-user PID; orphan detection via `kill -0`. | Exclusive Read/None lock held on the `.want` file; orphan detection via lock probe. |
| Router spawn | `nohup bash telegram-router.sh & disown` from ask-user when not alive. | `Start-Process pwsh -WindowStyle Hidden`. |

## Notes & limitations

- Bot token is sensitive. Anyone who has it can post to your chat. Keep it
  in env vars / `state/.env`, never check it in. The scripts read it only
  from those sources, never hardcode it. The `.gitignore` excludes
  `state/` (which contains `router.log` with verbatim chat text and
  `.env` with credentials).
- `setMessageReaction` (used for the 👀 ack) requires Bot API 7.0+, which
  has been live on Telegram since early 2024. If reactions silently fail
  (e.g. group chat without bot admin), the reply still routes — only the
  visual ack is missing.
- Multi-session safe: many Claude sessions can share one chat. The router
  is a singleton (lock-guarded) so `getUpdates` is never raced.
- Long-lived blocking: ask-user with `--timeout-seconds 0` /
  `-TimeoutSeconds 0` will block indefinitely. Use the shutdown switch
  above to break out cleanly.

## License

MIT — do whatever, no warranty.
