<#
.SYNOPSIS
    Blocking ask-the-user helper. Sends a question to Telegram, then blocks
    until the user replies (using Telegram's reply feature) to that specific
    message. Prints the reply text on stdout.

.DESCRIPTION
    Multi-session safe. This script is now a thin client over
    Telegram-Router.ps1, which is the single getUpdates poller per machine.

    Flow:
      1. (Unless -SkipTelegram) post the question to $env:TELEGRAM_CHAT_ID
         and capture the resulting message_id as the "target" reply id.
      2. Create state\want\<targetMsgId> and hold an exclusive lock on it
         (lock = "I am still waiting for this reply"). The router cleans up
         unlocked .want files as orphans.
      3. Ensure the router is running (start it detached if not).
      4. Wait for state\reply\<targetMsgId> to appear (the router writes it
         when a matching Telegram reply arrives), then read+delete it.
      5. Print the reply text on stdout.

    Exit codes: 0 = answered; 1 = timed out; 2 = setup error.

.PARAMETER Question
    Question text. Sent to Telegram unless -SkipTelegram is supplied.

.PARAMETER ReplyToMessageId
    With -SkipTelegram, the caller already sent the question and must pass
    the message_id of THAT outbound message. Replies that don't target this
    id are ignored.

.PARAMETER IssueNumber
    Optional. Kept for backwards compatibility. Appended to the question
    header.

.PARAMETER Repo
    Optional. Unused; kept for backwards compatibility.

.PARAMETER RespondingUser
    Optional. Ignored; replies are filtered by reply_to_message_id, not
    username. Kept for backwards compatibility.

.PARAMETER TimeoutSeconds
    Max seconds to wait for a reply. Default 86400 (24h). 0 = no timeout.

.PARAMETER PollSeconds
    Unused (router does the long-polling). Kept for backwards compat.

.PARAMETER SkipTelegram
    Don't send the question (caller already pinged). Caller must pass
    -ReplyToMessageId.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Question,
    [long]   $ReplyToMessageId = 0,
    [int]    $IssueNumber  = 0,
    [string] $Repo,
    [string] $RespondingUser = '',
    [int]    $TimeoutSeconds = 86400,
    [int]    $PollSeconds    = 25,
    [switch] $SkipTelegram
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Translate literal escape sequences in caller-provided text. AIs sometimes
# pass strings containing the two characters "\n" rather than a real newline
# (because their tool wrapper didn't interpret the escape). Convert them
# back to real whitespace before sending to Telegram. Order matters: \r\n
# first so it doesn't get split, then \n, then \t.
function Convert-EscapeSequences([string]$s) {
    if ($null -eq $s) { return $s }
    $s = $s -replace '\\r\\n', "`r`n"
    $s = $s -replace '\\n',    "`n"
    $s = $s -replace '\\r',    "`r"
    $s = $s -replace '\\t',    "`t"
    return $s
}

$token = $env:TELEGRAM_BOT_TOKEN
$chat  = $env:TELEGRAM_CHAT_ID
if (-not $token) { Write-Error 'TELEGRAM_BOT_TOKEN env var not set.'; exit 2 }
if (-not $chat)  { Write-Error 'TELEGRAM_CHAT_ID env var not set.';  exit 2 }

# State dirs (must match router's $StateDir resolution).
$stateDir = Join-Path $PSScriptRoot '..\state'
$stateDir = (New-Item -ItemType Directory -Path $stateDir -Force).FullName
$wantDir   = Join-Path $stateDir 'want'
$replyDir  = Join-Path $stateDir 'reply'
$lockPath  = Join-Path $stateDir 'router.lock'
$flagPath  = Join-Path $stateDir 'shutdown.flag'
$routerPs1 = Join-Path $PSScriptRoot 'Telegram-Router.ps1'
New-Item -ItemType Directory -Path $wantDir  -Force | Out-Null
New-Item -ItemType Directory -Path $replyDir -Force | Out-Null

function Read-ShutdownReason {
    if (-not (Test-Path -LiteralPath $flagPath)) { return $null }
    try {
        $raw  = [System.IO.File]::ReadAllText($flagPath, [System.Text.UTF8Encoding]::new($false))
        $obj  = $raw | ConvertFrom-Json
        if ($obj.reason) { return [string]$obj.reason } else { return 'Shutdown flag present (no reason).' }
    } catch {
        return 'Shutdown flag present (unparseable).'
    }
}

# Refuse to start if shutdown flag present.
$shutdownReason = Read-ShutdownReason
if ($shutdownReason) {
    Write-Output "__TELEGRAM_SHUTDOWN__: $shutdownReason"
    exit 3
}

$apiBase = "https://api.telegram.org/bot$token"

# 1. Send the question (or accept caller's id).
$Question = Convert-EscapeSequences $Question
$targetMsgId = $ReplyToMessageId
$sentAt = [long](Get-Date -UFormat %s)  # default: now (used when -SkipTelegram)
if (-not $SkipTelegram) {
    $headerPrefix = if ($IssueNumber -gt 0) { "[issue #$IssueNumber] " } else { '' }
    $body = @{
        chat_id = $chat
        text    = "${headerPrefix}$Question"
    } | ConvertTo-Json -Compress
    try {
        $sent = Invoke-RestMethod -Method POST -Uri "$apiBase/sendMessage" `
            -Body $body -ContentType 'application/json'
        if (-not $sent.ok) {
            Write-Error "sendMessage ok=false: $($sent | ConvertTo-Json -Depth 5 -Compress)"
            exit 2
        }
        $targetMsgId = [long]$sent.result.message_id
        if ($sent.result.date) { $sentAt = [long]$sent.result.date }
    } catch {
        Write-Error "Telegram sendMessage failed: $_"
        exit 2
    }
} elseif ($targetMsgId -le 0) {
    Write-Error "-SkipTelegram requires -ReplyToMessageId."
    exit 2
}
[Console]::Error.WriteLine("[Ask-User] target msg_id=$targetMsgId sent_at=$sentAt")

# 2. Take exclusive .want lock and write sibling .meta with sent_at.
$wantPath  = Join-Path $wantDir  "$targetMsgId"
$metaPath  = "$wantPath.meta"
$replyPath = Join-Path $replyDir "$targetMsgId"
# Pre-clean any stale reply file from a previous orphaned attempt.
if (Test-Path -LiteralPath $replyPath) {
    try { Remove-Item -LiteralPath $replyPath -Force } catch {}
}
try {
    $wantHandle = [System.IO.File]::Open($wantPath, 'OpenOrCreate', 'Read', 'None')
} catch {
    Write-Error "Could not lock $wantPath : $_"
    exit 2
}
try {
    [System.IO.File]::WriteAllText($metaPath, "{`"sent_at`":$sentAt}", [System.Text.UTF8Encoding]::new($false))
} catch {
    [Console]::Error.WriteLine("[Ask-User] failed to write meta $metaPath : $_")
}

function Cleanup {
    param($Handle, $WantPath, $MetaPath)
    try { if ($Handle) { $Handle.Dispose() } } catch {}
    try { if (Test-Path -LiteralPath $WantPath) { Remove-Item -LiteralPath $WantPath -Force } } catch {}
    try { if ($MetaPath -and (Test-Path -LiteralPath $MetaPath)) { Remove-Item -LiteralPath $MetaPath -Force } } catch {}
}

# 3. Ensure router is running. We just try to start it; the router itself
#    uses an exclusive lock on router.lock to enforce singleton, so a second
#    invocation exits cleanly without doing anything.
$needSpawn = $true
if (Test-Path -LiteralPath $lockPath) {
    try {
        $probe = [System.IO.File]::Open($lockPath, 'Open', 'Read', 'None')
        $probe.Dispose()
        # Lock available -> no live router.
    } catch {
        # Locked -> live router.
        $needSpawn = $false
    }
}
if ($needSpawn) {
    [Console]::Error.WriteLine("[Ask-User] spawning router...")
    try {
        Start-Process -FilePath 'pwsh' `
            -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-File', $routerPs1) `
            -WindowStyle Hidden | Out-Null
    } catch {
        Cleanup $wantHandle $wantPath $metaPath
        Write-Error "Failed to spawn router: $_"
        exit 2
    }
    # Give it a moment to grab the lock.
    Start-Sleep -Milliseconds 300
}

# 4. Wait for reply file to appear.
$start = Get-Date
while ($true) {
    if ($TimeoutSeconds -gt 0 -and ((Get-Date) - $start).TotalSeconds -gt $TimeoutSeconds) {
        Cleanup $wantHandle $wantPath $metaPath
        Write-Error "Timed out after $TimeoutSeconds seconds waiting for a Telegram reply to msg_id=$targetMsgId."
        exit 1
    }
    # Shutdown flag check: emit sentinel and exit cleanly so the calling
    # AI knows not to re-enter or continue.
    $shutdownReason = Read-ShutdownReason
    if ($shutdownReason) {
        Cleanup $wantHandle $wantPath $metaPath
        Write-Output "__TELEGRAM_SHUTDOWN__: $shutdownReason"
        exit 3
    }
    if (Test-Path -LiteralPath $replyPath) {
        try {
            $text = [System.IO.File]::ReadAllText($replyPath, [System.Text.UTF8Encoding]::new($false))
        } catch {
            Start-Sleep -Milliseconds 200
            continue
        }
        try { Remove-Item -LiteralPath $replyPath -Force } catch {}
        Cleanup $wantHandle $wantPath $metaPath
        Write-Output $text
        exit 0
    }

    # Periodically re-spawn router if it died (e.g. idle exit while we were
    # mid-wait and router hadn't seen our want yet).
    if (-not (Test-Path -LiteralPath $lockPath)) {
        try {
            Start-Process -FilePath 'pwsh' `
                -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-File', $routerPs1) `
                -WindowStyle Hidden | Out-Null
            Start-Sleep -Milliseconds 300
        } catch {}
    } else {
        # Lock file exists; verify it's actually held.
        try {
            $probe = [System.IO.File]::Open($lockPath, 'Open', 'Read', 'None')
            $probe.Dispose()
            # Stale lock file. Respawn.
            try {
                Start-Process -FilePath 'pwsh' `
                    -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-File', $routerPs1) `
                    -WindowStyle Hidden | Out-Null
                Start-Sleep -Milliseconds 300
            } catch {}
        } catch { }  # locked = healthy
    }

    Start-Sleep -Milliseconds 500
}
