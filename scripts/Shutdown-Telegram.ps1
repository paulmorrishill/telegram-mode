<#
.SYNOPSIS
    Globally close down all waiting Ask-User.ps1 / Telegram-Router.ps1
    processes. Writes a shutdown flag that:
      - active Ask-Users detect on their next poll, then exit with code 3
        and emit a sentinel string ("__TELEGRAM_SHUTDOWN__: <reason>") on
        stdout. The calling AI must NOT re-enter Ask-User and must NOT
        continue the conversation when it sees that sentinel.
      - the router daemon detects on its next loop iteration and exits.
      - new Ask-User invocations refuse to start until the flag is cleared.

    Use this before editing the skill code so existing sessions don't
    auto-relaunch a stale router or keep blocking on Telegram replies.

.DESCRIPTION
    Mechanism: writes $state\shutdown.flag with a JSON payload containing
    the reason and a timestamp. Optionally pings Telegram so the user sees
    a single "shutdown" message. To re-enable the skill, run with -Reset
    (or just delete the flag file).

.PARAMETER Reason
    Free-text reason. Echoed in the sentinel and (if -Notify) the Telegram
    message. Default: "Closed by user. Do not re-initiate, do not continue
    the conversation."

.PARAMETER Notify
    Send one Telegram message announcing the shutdown. Skipped if the env
    vars aren't set.

.PARAMETER Reset
    Remove the flag file. New Ask-User invocations will then succeed
    again. Telegram is NOT pinged on reset.

    Exit codes: 0 = ok; 2 = state-dir setup failure.
#>
[CmdletBinding()]
param(
    [string] $Reason = 'Closed by user. Do not re-initiate, do not continue the conversation.',
    [switch] $Notify,
    [switch] $Reset
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

try {
    $stateDir = Join-Path $PSScriptRoot '..\state'
    $stateDir = (New-Item -ItemType Directory -Path $stateDir -Force).FullName
} catch {
    Write-Error "Failed to prepare state dir: $_"
    exit 2
}
$flagPath = Join-Path $stateDir 'shutdown.flag'

if ($Reset) {
    if (Test-Path -LiteralPath $flagPath) {
        Remove-Item -LiteralPath $flagPath -Force
        "shutdown flag removed: $flagPath"
    } else {
        "no shutdown flag present at $flagPath"
    }
    exit 0
}

$payload = @{
    reason     = $Reason
    created_at = (Get-Date).ToString('o')
    created_by_pid = $PID
} | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText($flagPath, $payload, [System.Text.UTF8Encoding]::new($false))
"shutdown flag written: $flagPath"

if ($Notify) {
    $token = $env:TELEGRAM_BOT_TOKEN
    $chat  = $env:TELEGRAM_CHAT_ID
    if ($token -and $chat) {
        try {
            $body = @{
                chat_id = $chat
                text    = "📟 telegram-mode SHUTDOWN — $Reason"
            } | ConvertTo-Json -Compress
            Invoke-RestMethod -Method POST `
                -Uri "https://api.telegram.org/bot$token/sendMessage" `
                -Body $body -ContentType 'application/json' | Out-Null
            "shutdown notification sent."
        } catch {
            Write-Warning "Telegram notify failed: $_"
        }
    } else {
        Write-Warning '-Notify requested but TELEGRAM_* env vars not set; skipping.'
    }
}

exit 0
