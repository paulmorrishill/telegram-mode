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

- Windows
- PowerShell 7+ (`pwsh` on `PATH`). The scripts use PS7-only features.
- Claude Code (or any tool that reads `~/.claude/skills/<skill>/SKILL.md`)
- A Telegram bot (free, takes 60 seconds to create — see Setup below)

## Install

```powershell
# Clone into your user-level Claude skills folder
git clone https://github.com/<you>/telegram-mode "$env:USERPROFILE\.claude\skills\telegram-mode"
```

Claude auto-discovers skills under `~/.claude/skills/`. No `settings.json`
edit needed.

## Setup (one-time)

**1. Create a bot.** Open Telegram, message
[@BotFather](https://t.me/BotFather), send `/newbot`, follow the prompts.
BotFather replies with a bot token like `1234567890:AAH...`.

**2. Run the setup wizard.** It opens a small dialog, validates the token,
asks you to send the bot its first message, captures the chat ID, and
persists both as User-scope env vars.

```powershell
pwsh -File "$env:USERPROFILE\.claude\skills\telegram-mode\scripts\Setup-Telegram.ps1"
```

Steps the wizard walks you through:
- Paste your bot token (input is masked).
- It validates via Telegram's `getMe`.
- It pops a dialog telling you to open Telegram, find your bot, hit START
  / send any message.
- It long-polls `getUpdates` until your message arrives, grabs the chat
  ID.
- Persists `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` (User scope), then
  sends a "✅ setup complete" message back to your chat.

**3. Open a NEW terminal** so the env vars load (existing terminals
won't see them).

**Manual setup (if you'd rather not run the wizard):** the wizard just
runs `getMe` to validate the token, polls `getUpdates` to find your chat
ID, then sets two env vars. Set them yourself:

```powershell
[Environment]::SetEnvironmentVariable('TELEGRAM_BOT_TOKEN', '<paste-token>',   'User')
[Environment]::SetEnvironmentVariable('TELEGRAM_CHAT_ID',   '<paste-chat-id>', 'User')
```

To find your chat ID without the wizard: send any message to your bot,
then visit `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser
and find `"chat":{"id": <NUMBER>, ...}`.

**Verify:**
```powershell
pwsh -File "$env:USERPROFILE\.claude\skills\telegram-mode\scripts\Send-Telegram.ps1" -Text "hello from skill"
```
You should get a message on your phone.

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

To globally close every waiting session (useful when editing the skill so
sessions don't auto-relaunch a stale router):

```powershell
pwsh -File "$env:USERPROFILE\.claude\skills\telegram-mode\scripts\Shutdown-Telegram.ps1" [-Reason "..."] [-Notify]

# Re-enable:
pwsh -File "$env:USERPROFILE\.claude\skills\telegram-mode\scripts\Shutdown-Telegram.ps1" -Reset
```

The flag causes every active `Ask-User.ps1` to exit code 3 with a
`__TELEGRAM_SHUTDOWN__: <reason>` sentinel on stdout. The skill's AI
instructions tell Claude to NOT re-enter, NOT continue, and NOT send any
further Telegram messages on seeing that sentinel.

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | Instructions Claude reads on activation |
| `scripts/Setup-Telegram.ps1` | One-time setup wizard (dialog: token → chat ID → env vars) |
| `scripts/Ask-User.ps1` | Sends a question, blocks until reply (thin client of router) |
| `scripts/Send-Telegram.ps1` | Fire-and-forget message send |
| `scripts/Telegram-Router.ps1` | Singleton getUpdates daemon, dispatches replies by `reply_to_message_id` |
| `scripts/Shutdown-Telegram.ps1` | Global kill switch |
| `state/` | Runtime state (gitignored — contains chat content in `router.log`) |

## Notes & limitations

- Bot token is sensitive. Anyone who has it can post to your chat. Keep it
  in env vars, never check it in. The scripts read it only from env, never
  hardcode it. The `.gitignore` excludes `state/` (which contains
  `router.log` with verbatim chat text).
- `setMessageReaction` (used for the 👀 ack) requires Bot API 7.0+, which
  has been live on Telegram since early 2024. If reactions silently fail
  (e.g. group chat without bot admin), the reply still routes — only the
  visual ack is missing.
- Multi-session safe: many Claude sessions can share one chat. The router
  is a singleton (file-locked) so `getUpdates` is never raced.
- Long-lived blocking: Ask-User.ps1 with `-TimeoutSeconds 0` will block
  indefinitely. Use the shutdown switch above to break out cleanly.

## License

MIT — do whatever, no warranty.
