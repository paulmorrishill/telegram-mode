<#
.SYNOPSIS
    Send a message to Paul via the Telegram Bot API.

.DESCRIPTION
    Designed for the autonomous Claude session to call as a one-shot
    notification helper:

        pwsh -NoProfile -File scripts/orchestrator/Send-Telegram.ps1 `
            -Text "Stuck on type error in foo.ts; running Ask-User.ps1 next"

    Reads $env:TELEGRAM_BOT_TOKEN and $env:TELEGRAM_CHAT_ID. Exits 0 on
    success, non-zero on transport / API error. Prints the Telegram message
    id on stdout for the caller to log.

.PARAMETER Text
    Message body. Markdown-V2 if -Markdown supplied; otherwise plain.

.PARAMETER Markdown
    Send with parse_mode=MarkdownV2. Caller is responsible for escaping
    reserved chars per Telegram spec.

.PARAMETER Silent
    Set disable_notification=true (no sound / banner).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Text,
    [switch] $Markdown,
    [switch] $Silent
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Translate literal "\n" / "\t" / "\r" / "\r\n" sequences into real
# whitespace. AIs sometimes pass these as literal two-char sequences
# because their tool wrapper didn't interpret the escape.
function Convert-EscapeSequences([string]$s) {
    if ($null -eq $s) { return $s }
    $s = $s -replace '\\r\\n', "`r`n"
    $s = $s -replace '\\n',    "`n"
    $s = $s -replace '\\r',    "`r"
    $s = $s -replace '\\t',    "`t"
    return $s
}
$Text = Convert-EscapeSequences $Text

$token = $env:TELEGRAM_BOT_TOKEN
$chat  = $env:TELEGRAM_CHAT_ID
if (-not $token) { Write-Error 'TELEGRAM_BOT_TOKEN env var not set.'; exit 2 }
if (-not $chat)  { Write-Error 'TELEGRAM_CHAT_ID env var not set.';  exit 2 }

$payload = @{
    chat_id = $chat
    text    = $Text
}
if ($Markdown) { $payload['parse_mode'] = 'MarkdownV2' }
if ($Silent)   { $payload['disable_notification'] = $true }

$uri = "https://api.telegram.org/bot$token/sendMessage"
try {
    $resp = Invoke-RestMethod -Method POST -Uri $uri -ContentType 'application/json' `
        -Body ($payload | ConvertTo-Json -Compress)
    if (-not $resp.ok) {
        Write-Error "Telegram API returned ok=false: $($resp | ConvertTo-Json -Depth 5 -Compress)"
        exit 1
    }
    Write-Output $resp.result.message_id
} catch {
    Write-Error "Telegram send failed: $_"
    exit 1
}
