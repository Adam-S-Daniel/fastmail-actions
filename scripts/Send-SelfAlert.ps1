#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Email a short text alert to the account owner over Fastmail JMAP.

.DESCRIPTION
  Sends one plain-text message with the given subject and body from
  SELF_ALERT_FROM to SELF_ALERT_TO (repo secrets; this repo is public, so no
  address lives in the code). The From address must already be a sending
  identity on the account.

  The subject is flattened to one line (CR/LF/tab runs become a single space)
  and trimmed; the body is trimmed. An empty subject or body is an error: an
  empty alert is never sent. The subject is capped at 200 characters and the
  body at 4000 (truncated, not an error).

  PRIVACY: stdout gets only a non-identifying status line. The addresses, the
  subject and the body are never printed or logged.

  Auth: FASTMAIL_API_TOKEN (the GitHub secret). For local testing set
  FASTMAIL_MOCK_DIR; set FASTMAIL_MOCK_OUTBOX to capture the email to a file.

.EXAMPLE
  $env:SELF_ALERT_FROM = 'alerts@example.net'; $env:SELF_ALERT_TO = 'alerts@example.net'
  ./Send-SelfAlert.ps1 -Subject 'Backup finished' -Body 'Nightly backup completed.'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Subject,
    [Parameter(Mandatory)][string]$Body
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$maxSubject = 200
$maxBody = 4000

$from = $env:SELF_ALERT_FROM
$to = $env:SELF_ALERT_TO
if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)) {
    throw 'SELF_ALERT_FROM and SELF_ALERT_TO must be set.'
}
$from = $from.Trim()
$to = $to.Trim()

$Subject = ($Subject -replace '[\r\n\t]+', ' ').Trim()
$Body = $Body.Trim()
if (-not $Subject) { throw 'Subject must not be empty.' }
if (-not $Body) { throw 'Body must not be empty.' }
if ($Subject.Length -gt $maxSubject) { $Subject = $Subject.Substring(0, $maxSubject).TrimEnd() }
if ($Body.Length -gt $maxBody) { $Body = $Body.Substring(0, $maxBody).TrimEnd() }

Import-Module (Join-Path $PSScriptRoot 'FastmailJmap.psm1') -Force

$token = Get-FastmailToken
$session = New-JmapSession -Token $token

Send-FastmailReport -Session $session -From $from -To $to -Subject $Subject -BodyText $Body | Out-Null

Write-Host 'self-alert sent'
