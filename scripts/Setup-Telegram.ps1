<#
.SYNOPSIS
    One-time setup wizard for the telegram-mode skill.

.DESCRIPTION
    Walks the user through:
      1. Paste bot token (masked dialog).
      2. Validate via Telegram getMe.
      3. Prompt user to send first message to the bot.
      4. Long-poll getUpdates to capture chat_id.
      5. Persist TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID as User-scope
         env vars.
      6. Send a confirmation message back so the user knows it works.

    Pre-req: user has already created a bot via @BotFather and has the
    token ready. Setup-Telegram.ps1 does NOT create the bot.

.PARAMETER NoPersist
    Validate and capture but don't persist. Shows the values so the user
    can set them manually.

.PARAMETER PollTimeoutSeconds
    How long to wait for the user's first message after the prompt
    dialog. Default 120s.

    Exit codes: 0 = ok; 1 = user cancelled / no message; 2 = unexpected error.
#>
[CmdletBinding()]
param(
    [switch] $NoPersist,
    [int]    $PollTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing       | Out-Null
} catch {
    Write-Error "Could not load WinForms (this script is Windows-only): $_"
    exit 2
}

function Show-Info  ($title, $msg) { [System.Windows.Forms.MessageBox]::Show($msg, $title, 'OK', 'Information') | Out-Null }
function Show-Error ($title, $msg) { [System.Windows.Forms.MessageBox]::Show($msg, $title, 'OK', 'Error')       | Out-Null }
function Show-YesNo ($title, $msg) {
    return ([System.Windows.Forms.MessageBox]::Show($msg, $title, 'YesNo', 'Question') -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Read-MaskedInput {
    param([string] $Prompt, [string] $Title = 'telegram-mode setup')
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = $Title
    $form.Size            = New-Object System.Drawing.Size(500, 210)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.TopMost         = $true

    $label          = New-Object System.Windows.Forms.Label
    $label.Text     = $Prompt
    $label.Location = New-Object System.Drawing.Point(15, 15)
    $label.Size     = New-Object System.Drawing.Size(460, 60)
    $form.Controls.Add($label)

    $tb              = New-Object System.Windows.Forms.TextBox
    $tb.Location     = New-Object System.Drawing.Point(15, 85)
    $tb.Size         = New-Object System.Drawing.Size(460, 25)
    $tb.PasswordChar = '*'
    $form.Controls.Add($tb)

    $ok                 = New-Object System.Windows.Forms.Button
    $ok.Text            = 'OK'
    $ok.Location        = New-Object System.Drawing.Point(305, 125)
    $ok.Size            = New-Object System.Drawing.Size(80, 30)
    $ok.DialogResult    = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)
    $form.AcceptButton  = $ok

    $cancel             = New-Object System.Windows.Forms.Button
    $cancel.Text        = 'Cancel'
    $cancel.Location    = New-Object System.Drawing.Point(395, 125)
    $cancel.Size        = New-Object System.Drawing.Size(80, 30)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)
    $form.CancelButton  = $cancel

    $result = $form.ShowDialog()
    $value  = $tb.Text
    $form.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $value
}

# 1. Get + validate token.
$token = $null
$botUsername = $null
while ($true) {
    $entered = Read-MaskedInput -Prompt @"
Paste your Telegram bot token from @BotFather.

Format: 1234567890:AA...
The input is masked. Click Cancel to abort.
"@
    if (-not $entered) {
        Show-Info 'Cancelled' 'Setup cancelled. No changes made.'
        exit 1
    }
    $token = $entered.Trim()

    try {
        $me = Invoke-RestMethod -Method GET -Uri "https://api.telegram.org/bot$token/getMe" -TimeoutSec 15
        if (-not $me.ok) { throw "API returned ok=false" }
        $botUsername = $me.result.username
        break
    } catch {
        if (-not (Show-YesNo 'Invalid token' "Telegram rejected that token:`n`n$_`n`nTry again?")) {
            exit 1
        }
    }
}

# 2. Drain any pre-existing updates so we don't pick up stale messages.
try {
    $drain = Invoke-RestMethod -Method GET -Uri "https://api.telegram.org/bot$token/getUpdates?timeout=0&limit=100" -TimeoutSec 15
    $offset = if ($drain.result.Count -gt 0) {
        ($drain.result | ForEach-Object { $_.update_id } | Measure-Object -Maximum).Maximum + 1
    } else { 0 }
    if ($offset -gt 0) {
        # Acknowledge the drain so Telegram clears them server-side.
        Invoke-RestMethod -Method GET -Uri "https://api.telegram.org/bot$token/getUpdates?offset=$offset&timeout=0&limit=1" -TimeoutSec 15 | Out-Null
    }
} catch {
    Show-Error 'Network error' "Could not query Telegram API:`n`n$_"
    exit 2
}

# 3. Ask user to send a message.
Show-Info 'Send first message' @"
Bot validated: @$botUsername

Now:
  1. Open Telegram.
  2. Search for @$botUsername (or open the chat with your bot).
  3. Press START — or just send any message ('hi' is fine).

Click OK after you've sent at least one message.
This dialog will then poll for up to $PollTimeoutSeconds seconds.
"@

# 4. Long-poll getUpdates until we see a message.
$chatId = $null
$start  = Get-Date
while (((Get-Date) - $start).TotalSeconds -lt $PollTimeoutSeconds) {
    try {
        $r = Invoke-RestMethod -Method GET -Uri "https://api.telegram.org/bot$token/getUpdates?offset=$offset&timeout=15&limit=10" -TimeoutSec 25
        foreach ($u in $r.result) {
            if ($u.update_id -ge $offset) { $offset = $u.update_id + 1 }
            $m = $u.message
            if (-not $m) { $m = $u.edited_message }
            if (-not $m -or -not $m.chat) { continue }
            $chatId = "$($m.chat.id)"
            break
        }
    } catch {
        Start-Sleep -Seconds 2
    }
    if ($chatId) { break }
}

if (-not $chatId) {
    Show-Error 'No messages received' "Didn't see a message in $PollTimeoutSeconds seconds. Make sure you sent something to @$botUsername then re-run this script."
    exit 1
}

# 5. Persist or display.
if ($NoPersist) {
    Show-Info 'Setup complete (not persisted)' @"
Bot:     @$botUsername
Chat ID: $chatId

To set the env vars manually (PowerShell):

[Environment]::SetEnvironmentVariable('TELEGRAM_BOT_TOKEN','<paste-token>','User')
[Environment]::SetEnvironmentVariable('TELEGRAM_CHAT_ID','$chatId','User')
"@
    exit 0
}

try {
    [Environment]::SetEnvironmentVariable('TELEGRAM_BOT_TOKEN', $token,  'User')
    [Environment]::SetEnvironmentVariable('TELEGRAM_CHAT_ID',   $chatId, 'User')
} catch {
    Show-Error 'Persist failed' "Could not write User env vars:`n`n$_`n`nValues:`nTELEGRAM_BOT_TOKEN = (your token)`nTELEGRAM_CHAT_ID = $chatId"
    exit 2
}

# 6. Send confirmation message.
try {
    $body = @{
        chat_id = $chatId
        text    = "✅ telegram-mode skill setup complete. You're ready — say 'telegram mode' to Claude in any session."
    } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method POST -Uri "https://api.telegram.org/bot$token/sendMessage" `
        -Body $body -ContentType 'application/json' -TimeoutSec 15 | Out-Null
} catch {
    # Non-fatal; persistence already worked.
}

Show-Info 'Setup complete' @"
Bot:     @$botUsername
Chat ID: $chatId

Env vars persisted (User scope).

IMPORTANT: open a NEW terminal so the new env vars load. Then say
'telegram mode' to Claude in any session to start using the skill.
"@
exit 0
