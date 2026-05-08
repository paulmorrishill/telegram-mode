<#
.SYNOPSIS
    Long-lived Telegram getUpdates router. Single poller per machine.
    Dispatches incoming replies to waiting Ask-User.ps1 clients via files.

.DESCRIPTION
    Solves the multi-session race on Telegram's getUpdates API. Multiple
    Ask-User.ps1 processes can be waiting concurrently; each registers a
    target_msg_id (the message they want a reply to). This router is the
    only process polling getUpdates. For each incoming message it checks
    reply_to_message.message_id against the active registrations and writes
    the reply text to a per-target file the matching Ask-User reads.

    Singleton enforcement: only one router runs per machine, guarded by an
    exclusive lock on $StateDir\router.lock.

    Idle shutdown: exits if no active registrations for $IdleSeconds.

    Crash recovery: registration files are exclusively locked by their
    Ask-User owner. The router treats unlocked .want files as orphans and
    deletes them.

.PARAMETER StateDir
    Directory used for inter-process state. Defaults to skill-local
    "state" folder.

.PARAMETER IdleSeconds
    Exit after this many consecutive seconds with no active registrations.
    Default 90.

.PARAMETER PollSeconds
    Telegram getUpdates long-poll timeout. Default 25 (Telegram allows 50).

    Exit codes:
      0 = clean exit (idle or another router already running)
      2 = setup error (env var missing, state dir failure)
#>
[CmdletBinding()]
param(
    [string] $StateDir     = "$PSScriptRoot\..\state",
    [int]    $IdleSeconds  = 90,
    [int]    $PollSeconds  = 25
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$token = $env:TELEGRAM_BOT_TOKEN
$chat  = $env:TELEGRAM_CHAT_ID
if (-not $token) { Write-Error 'TELEGRAM_BOT_TOKEN env var not set.'; exit 2 }
if (-not $chat)  { Write-Error 'TELEGRAM_CHAT_ID env var not set.';  exit 2 }

# Resolve state dir to absolute and ensure subdirs exist.
$StateDir = (Resolve-Path -LiteralPath (New-Item -ItemType Directory -Path $StateDir -Force).FullName).Path
$wantDir  = Join-Path $StateDir 'want'
$replyDir = Join-Path $StateDir 'reply'
$lockPath = Join-Path $StateDir 'router.lock'
$flagPath = Join-Path $StateDir 'shutdown.flag'
$logPath  = Join-Path $StateDir 'router.log'
New-Item -ItemType Directory -Path $wantDir  -Force | Out-Null
New-Item -ItemType Directory -Path $replyDir -Force | Out-Null

function Write-Log([string]$msg) {
    $line = "[$(Get-Date -Format 'HH:mm:ss.fff')] $msg"
    [Console]::Error.WriteLine($line)
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch {}
}

# Singleton lock.
try {
    $lockHandle = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'Write', 'None')
} catch {
    Write-Log "another router already holds $lockPath; exiting."
    exit 0
}
try {
    $pidBytes = [System.Text.Encoding]::UTF8.GetBytes("$PID`n")
    $lockHandle.SetLength(0)
    $lockHandle.Write($pidBytes, 0, $pidBytes.Length)
    $lockHandle.Flush()
} catch {}

Write-Log "router started, pid=$PID, statedir=$StateDir"

$apiBase = "https://api.telegram.org/bot$token"

# Initial offset = high-water of any pending updates so we don't replay
# ancient messages.
try {
    $drain = Invoke-RestMethod -Method GET -Uri "$apiBase/getUpdates?timeout=0&limit=100"
} catch {
    Write-Log "drain failed: $_"
    exit 2
}
$offset = if ($drain.result.Count -gt 0) {
    ($drain.result | ForEach-Object { $_.update_id } | Measure-Object -Maximum).Maximum + 1
} else { 0 }
Write-Log "drained $($drain.result.Count) prior; starting offset=$offset"

function Get-ActiveWants {
    # Returns hashtable: target_msg_id (long) -> sent_at (long, unix sec).
    # Cleans up orphans. Reads sibling .meta for sent_at; defaults to 0 if
    # missing/unparseable.
    $active = @{}
    $files = @(Get-ChildItem -LiteralPath $wantDir -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $name = $f.Name
        if ($name -notmatch '^\d+$') { continue }   # skip .meta and non-numeric
        $idLong = [long]$name
        $isOrphan = $false
        try {
            $h = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'None')
            $h.Dispose()
            $isOrphan = $true
        } catch {
            $isOrphan = $false
        }
        if ($isOrphan) {
            try { Remove-Item -LiteralPath $f.FullName -Force } catch {}
            try { Remove-Item -LiteralPath ($f.FullName + '.meta') -Force -ErrorAction SilentlyContinue } catch {}
            Write-Log "orphan .want cleaned: $name"
            continue
        }
        $sentAt = 0
        $metaPath = $f.FullName + '.meta'
        if (Test-Path -LiteralPath $metaPath) {
            try {
                $raw  = [System.IO.File]::ReadAllText($metaPath, [System.Text.UTF8Encoding]::new($false))
                $meta = $raw | ConvertFrom-Json
                if ($meta.sent_at) { $sentAt = [long]$meta.sent_at }
            } catch {
                Write-Log "meta parse failed for $name : $_"
            }
        }
        $active[$idLong] = $sentAt
    }
    return ,$active   # comma prevents PowerShell from unrolling the hashtable
}

$idleSince = $null
$lastWantsLog = ''
while ($true) {
    if (Test-Path -LiteralPath $flagPath) {
        Write-Log "shutdown flag detected; exiting."
        break
    }
    $wants = Get-ActiveWants
    # Log when active-want set changes so we can diagnose routing decisions.
    $sig = ($wants.Keys | Sort-Object) -join ','
    if ($sig -ne $lastWantsLog) {
        Write-Log "active wants: [$sig] (count=$($wants.Count))"
        $lastWantsLog = $sig
    }
    if ($wants.Count -eq 0) {
        if (-not $idleSince) { $idleSince = Get-Date }
        if (((Get-Date) - $idleSince).TotalSeconds -ge $IdleSeconds) {
            Write-Log "idle for $IdleSeconds s; exiting."
            break
        }
        Start-Sleep -Seconds 1
        continue
    } else {
        $idleSince = $null
    }

    try {
        $url = "$apiBase/getUpdates?offset=$offset&timeout=$PollSeconds&limit=10"
        $resp = Invoke-RestMethod -Method GET -Uri $url -TimeoutSec ($PollSeconds + 10)
    } catch {
        Write-Log "getUpdates error: $_"
        Start-Sleep -Seconds 3
        continue
    }
    if (-not $resp.ok) { Start-Sleep -Seconds 3; continue }

    # Pre-compute "latest want" for orphan-message routing (non-reply msgs
    # arriving after the most recent question are treated as that
    # question's answer, with a 1-second guard against snipes).
    $latestWantId = $null
    $latestWantAt = 0
    foreach ($k in $wants.Keys) {
        if ($wants[$k] -gt $latestWantAt) { $latestWantAt = $wants[$k]; $latestWantId = $k }
    }

    foreach ($u in $resp.result) {
        if ($u.update_id -ge $offset) { $offset = $u.update_id + 1 }
        $msg = $u.message
        if (-not $msg) { $msg = $u.edited_message }
        if (-not $msg) { continue }
        if (-not $msg.chat) { continue }
        if ("$($msg.chat.id)" -ne "$chat") { continue }
        if (-not $msg.text) { continue }   # ignore stickers/photos/etc

        $replyTarget = $null
        if ($msg.reply_to_message) {
            $replyTarget = [long]$msg.reply_to_message.message_id
            if (-not $wants.ContainsKey($replyTarget)) {
                Write-Log "drop msg_id=$($msg.message_id) reply_to=$replyTarget (no active want)"
                continue
            }
        } else {
            # Orphan (non-reply) routing: attach to the most recent active
            # want, but only if the user's message is strictly later than
            # the question's send time (>= sent_at + 1s, since Telegram
            # timestamps are second-precision; this satisfies the 500ms
            # snipe guard).
            if (-not $latestWantId) {
                Write-Log "drop msg_id=$($msg.message_id) (no reply_to, no active wants)"
                continue
            }
            $msgDate = [long]$msg.date
            if ($msgDate -le $latestWantAt) {
                Write-Log "drop msg_id=$($msg.message_id) (no reply_to, msg.date=$msgDate <= sent_at=$latestWantAt; snipe guard)"
                continue
            }
            $replyTarget = [long]$latestWantId
            Write-Log "orphan-route msg_id=$($msg.message_id) -> latest want=$replyTarget (msg.date=$msgDate, sent_at=$latestWantAt)"
        }

        # Match. Write reply file atomically (temp + move).
        $finalPath = Join-Path $replyDir "$replyTarget"
        $tmpPath   = "$finalPath.tmp"
        try {
            [System.IO.File]::WriteAllText($tmpPath, $msg.text, [System.Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $tmpPath -Destination $finalPath -Force
            Write-Log "dispatched reply for target=$replyTarget (msg_id=$($msg.message_id))"
        } catch {
            Write-Log "failed to write reply file for $replyTarget : $_"
            continue
        }

        # Ack via 👀 reaction on the user's message (no chat-spam). Falls
        # back silently if the API rejects it (e.g. bot lacks permission or
        # the chat doesn't support reactions); the AI's next message will
        # serve as the natural ack instead.
        try {
            $reactBody = @{
                chat_id    = $chat
                message_id = $msg.message_id
                reaction   = @(@{ type = 'emoji'; emoji = '👀' })
                is_big     = $false
            } | ConvertTo-Json -Compress -Depth 5
            Invoke-RestMethod -Method POST -Uri "$apiBase/setMessageReaction" `
                -Body $reactBody -ContentType 'application/json' | Out-Null
        } catch {
            Write-Log "reaction failed for msg_id=$($msg.message_id): $_ (continuing without ack)"
        }
    }
}

try { $lockHandle.Dispose() } catch {}
try { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue } catch {}
Write-Log "router stopped."
exit 0
