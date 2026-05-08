---
name: telegram-mode
description: Route every clarifying question AND every turn-end through Telegram instead of the terminal. The session never ends until the user sends `!quit` on Telegram — every turn finishes by blocking on Ask-User.ps1 so the connection is never dropped. Use when user says "switch to telegram mode", "telegram mode", "telegram mode on", "ask via telegram", "talk to me on telegram", or invokes /telegram-mode. Deactivates only via Telegram `!quit` reply, or terminal-side "exit telegram mode" / "stop telegram mode" / "normal mode".
---

# Telegram Mode

You ask. Phone buzzes. User replies on phone. You continue. **You never end the message stream** — every turn finishes by blocking on `Ask-User.ps1` waiting for the next instruction, until the user sends `!quit`.

> **Path note for the AI:** all script paths below use `<skill-dir>` as a placeholder. Substitute it with the absolute path of the directory holding this `SKILL.md` (announced at skill load, e.g. "Base directory for this skill: …"). The `scripts\` subfolder of `<skill-dir>` contains `Ask-User.ps1`, `Send-Telegram.ps1`, `Telegram-Router.ps1`, `Shutdown-Telegram.ps1`.

## Activation

Trigger phrases (case-insensitive): "switch to telegram mode", "telegram mode", "telegram mode on", "ask via telegram", "talk to me on telegram", `/telegram-mode`.

On activation:

1. **Check env vars** in current session:
   ```powershell
   pwsh -NoProfile -Command "if ($env:TELEGRAM_BOT_TOKEN -and $env:TELEGRAM_CHAT_ID) { 'ok' } else { 'missing' }"
   ```
   If `missing` → refuse with: `telegram mode unavailable — set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID (see README.md in the skill folder for setup).` Stay in normal mode.
2. **Pick a conversation slug.** Short PascalCase tag summarising current work (≤20 chars, letters only, no spaces). Examples: `AddTelegram`, `FixAuthBug`, `RefactorDb`, `Research`, `PlanMobileSync`. Derive from the user's most recent task/request. If nothing specific is in flight yet, use `General`. **Lock this slug for the entire session** — do NOT change it mid-session even if the topic shifts (the user can `!quit` and reactivate to get a new slug).
3. **Send activation ping** (fire-and-forget), prefixed with the slug:
   ```
   pwsh -NoProfile -File "<skill-dir>\scripts\Send-Telegram.ps1" -Text "<Slug>: 📟 telegram mode on — REPLY to my messages (Telegram reply feature) to answer. Plain messages are ignored. Send !quit (as a reply) to end the session."
   ```

   **Reply discipline:** every Claude session in telegram mode shares the same chat. Two ways for the user to answer:
   - **Telegram reply feature** (long-press → Reply, or swipe) — routes to the specific session whose message they replied to. Always works, even mid-conversation across sessions.
   - **Plain message after a question** — if the user just types a message in the chat, the router attaches it to the *most recently sent* question across all active sessions, provided the message arrived strictly later (>1s) than that question. Convenience for the common single-active-session case; for multi-session, prefer the reply feature.
4. **Acknowledge in terminal** (one line): `📟 telegram mode active [slug=<Slug>] — every turn waits on Telegram. Send !quit on Telegram to exit.`
5. **Remember mode is active and the slug** for the rest of the session. Do not drift back to terminal questions. **Every turn must end by blocking on Ask-User.ps1** (see "Turn-end wait" below). **Every Telegram message — every Send-Telegram.ps1 `-Text` and every Ask-User.ps1 `-Question` — must start with `<Slug>: `** (slug, colon, space).

## Per-question mechanic

Whenever you would otherwise ask the user a question — clarification, plan check (outside of `ExitPlanMode`), choice between options, anything — do this instead:

1. Print one terse status line in the terminal: `📟 asking via telegram: "<first 60 chars of question>…"`
2. Run the blocking script via the **Bash tool with `run_in_background: true`** (the PowerShell tool's 10-min cap would kill long waits). **Prefix the question with `<Slug>: `**:
   ```
   pwsh -NoProfile -File "<skill-dir>\scripts\Ask-User.ps1" -Question "<Slug>: <your question text>" -TimeoutSeconds 0
   ```
   `-TimeoutSeconds 0` = no timeout. Script blocks until user replies on Telegram.
3. **Wait for the shell to complete.** You will be notified. Do not poll, do not ScheduleWakeup, do not start other work that depends on the answer.
4. Read the captured stdout — the last line is the user's reply text. Treat it exactly as if the user had typed that text in the terminal.
5. Continue the task using that reply.

### Multi-choice (AskUserQuestion override)

When telegram mode is active, **do not call AskUserQuestion**. Multi-choice still goes through `Ask-User.ps1`. Render options as numbered list inside the `-Question` text:

```
<question text>

Reply with a number or free text:
1. <option label> — <option description>
2. <option label> — <option description>
3. <option label> — <option description>
```

Parse the reply: a bare `1`/`2`/`3`/`4` (optionally with trailing punctuation) selects that option. Anything else is treated as an "Other" free-text answer.

### Question text rules

- Single line preferred; multi-line OK (Telegram handles it).
- Quote arguments properly — pass via `-Question "..."` or escape inner double-quotes.
- No markdown formatting (script sends plain text). If you need code/paths, surround with backticks just for visual cue; Telegram won't render them.
- Don't truncate. Telegram allows 4096 chars.

## Turn-end wait — NEVER end the message stream

**Critical rule.** While telegram mode is active, you NEVER finish a turn by handing control back to the terminal. Every turn ends by blocking on `Ask-User.ps1` so the user always has an open channel to send the next instruction. The only thing that ends the session is the user replying `!quit` on Telegram.

### Mechanic at end of every turn

1. Build a short status line summarising what just happened (≤120 chars). Examples (slug `AddTelegram`):
   - `AddTelegram: ✅ done: renamed foo→bar in 3 files. tests pass.`
   - `AddTelegram: ✅ research done: auth uses JWT in middleware/auth.ts:42.`
   - `AddTelegram: ⚠️ blocked: build failed with TS2304. logs above.`
   - `AddTelegram: (starting up)` — for the very first wait after activation, when no work was done yet.
2. Append a fixed prompt: `\n\nNext? (send !quit to exit telegram mode)`
3. Run via Bash tool, `run_in_background: true`. **Question text must start with `<Slug>: `**:
   ```
   pwsh -NoProfile -File "<skill-dir>\scripts\Ask-User.ps1" -Question "<Slug>: <status>\n\nNext? (send !quit to exit telegram mode)" -TimeoutSeconds 0
   ```
4. Wait for the shell to complete. Read stdout — that text is the user's next instruction.
5. **If reply is exactly `!quit`** (case-insensitive, trimmed) → run the deactivation flow (see below) and end the turn for real. Do not re-enter Ask-User.
6. **Otherwise** → treat the reply as the user's next prompt. Begin a new turn of work, then end again with another Ask-User wait. Loop forever until `!quit`.

### Mid-turn questions still use the same mechanic

If you genuinely need to ask the user something mid-task (clarification, choice, dangerous-op confirm), use Ask-User.ps1 exactly as described in "Per-question mechanic". The only difference between a mid-turn question and a turn-end wait is the `-Question` text — the mechanic is identical. The user replying `!quit` mid-task also exits cleanly (treat the in-flight task as cancelled, run deactivation, end the turn).

### Why no separate "done ping"

The status line at the top of the turn-end Ask-User question replaces the done ping. One Telegram message per turn, not two. User sees what happened AND can reply with the next instruction in the same notification.

## Deactivation

Triggers (any of):
- Telegram reply `!quit` (case-insensitive, trimmed) — primary path.
- Terminal-side phrases: "exit telegram mode", "stop telegram mode", "normal mode". (Note: "stop caveman" does NOT count — that's the caveman skill.)
- **Global shutdown flag** — Ask-User.ps1 stdout begins with `__TELEGRAM_SHUTDOWN__:` followed by a reason string. See "Shutdown sentinel" below.

On deactivation:
1. Send a final ping (still slug-prefixed): `pwsh -NoProfile -File "...\Send-Telegram.ps1" -Text "<Slug>: 📟 telegram mode off — channel closed"` — **skip this if the trigger was the shutdown sentinel** (the user explicitly does NOT want any more activity).
2. Acknowledge in terminal: `telegram mode off — questions back to terminal.`
3. End the current turn normally (do NOT re-enter Ask-User). Resume normal terminal-based questions and AskUserQuestion behaviour on subsequent turns.

### Shutdown sentinel — `__TELEGRAM_SHUTDOWN__`

The user can globally close every waiting session (across all Claude instances on the machine) by running:

```
pwsh -NoProfile -File "<skill-dir>\scripts\Shutdown-Telegram.ps1" [-Reason "..."] [-Notify]
```

This writes `state\shutdown.flag`. Every active `Ask-User.ps1` detects it on its next poll, exits cleanly, and emits a single line on stdout:

```
__TELEGRAM_SHUTDOWN__: <reason text>
```

(Exit code 3.) New `Ask-User.ps1` invocations also refuse to start while the flag is present and emit the same sentinel.

**When you read this sentinel from any Ask-User invocation:**
1. Do NOT re-enter Ask-User. Do NOT spawn a new question.
2. Do NOT send any further Telegram messages (no deactivation ping, no done ping — the user wants total silence).
3. Do NOT continue the conversation logic that was waiting on the reply. The reply isn't coming.
4. End the current turn with a single terse terminal acknowledgement, e.g.: `telegram mode shut down by user — <reason>. holding.`
5. On subsequent user turns (if they continue typing in the terminal), behave as if telegram mode is off. Do not try to reactivate it.

To re-enable telegram mode after shutdown: user runs `Shutdown-Telegram.ps1 -Reset` (clears the flag), then says a normal activation phrase.

## Boundaries

- **`ExitPlanMode` stays terminal-side.** It needs the IDE-side approval card. Inside plan mode, clarifying questions in Phases 1–3 still route through Telegram; only the final approval gate stays terminal.
- **Destructive-action confirmations** (rm -rf, force push, dropping tables) — still route through Telegram, but be extra explicit in the question text about what's about to happen and what reply you'll treat as authorization.
- **Errors from the script:**
  - exit 2 (env var missing) → tell user once, fall back to terminal for that question, stay in mode.
  - exit 1 (timeout) → won't happen with `-TimeoutSeconds 0`. If it somehow does, retry with `-SkipTelegram -ReplyToMessageId <id>` (the question was already sent; supply the original message_id so the filter still works).
  - shell crash / network blip → retry once with `-SkipTelegram -ReplyToMessageId <id>` so we don't double-send. If the original id wasn't captured, accept that you have to re-send (drop `-SkipTelegram`).
- **Multi-session safety:** safe by construction. `Ask-User.ps1` is now a thin client. The actual `getUpdates` polling is done by a single `Telegram-Router.ps1` daemon (auto-spawned on first use, idle-exits after 90s of no waiters). Multiple Ask-User invocations register their `target_msg_id` via `state\want\<id>` files; the router fans incoming replies out to `state\reply\<id>` files by `reply_to_message.message_id`. No `getUpdates` race — there is only ever one poller.
- **Router internals (don't worry about this normally):** `state\` directory lives at `<skill-dir>\state\`. Contains: `router.lock` (singleton lock + pid), `want\<id>` (one per active waiter, exclusively locked by the Ask-User process — orphans get cleaned by the router), `reply\<id>` (UTF-8 text written by router on dispatch), `router.log` (append-only trace). Safe to delete the whole `state\` folder when nothing is running.
- **Code/commits/PR text:** write normally. Telegram mode only changes how you ask the user questions, not the content of code or commit messages.
- **Don't mix with caveman mode rules** — they layer fine, but the question text routed to Telegram should be readable, not maximum-compressed.

## Self-check

Before ending any turn while telegram mode is active:
- Did I end with an Ask-User.ps1 wait? **If not, I am breaking the rule** — re-enter Ask-User immediately with a status line.
- Was the last Telegram reply `!quit`? Only then am I allowed to end the turn without re-waiting.
- Is the status line in my turn-end question accurate and ≤120 chars?
- **Does every Telegram message text start with `<Slug>: `?** Activation ping, mid-turn question, turn-end wait, deactivation ping — all of them.

Before sending any mid-turn question:
- Is the question text complete enough that I can act on the reply without another round-trip?
- Have I parsed the reply for `!quit` before treating it as a question answer?
- Slug prefix present?
