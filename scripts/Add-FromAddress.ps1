#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Add one or more email addresses to a Fastmail account as selectable "From"
  (sending) identities, via a single JMAP Identity/set call.

.DESCRIPTION
  Idempotent: addresses already present are skipped. Follows PowerShell -WhatIf
  conventions: with -WhatIf it reports the pre-existing From addresses and those
  that WOULD be added, making no changes; without it, it makes the changes and
  reports what was already present and what was newly added.

  PRIVACY: the report (which contains addresses) is emailed to the account, from
  the account, over JMAP EmailSubmission — it is NEVER printed or logged. stdout
  gets only a non-identifying confirmation.

  Auth: FASTMAIL_API_TOKEN (the GitHub secret). Report routing:
  FASTMAIL_REPORT_FROM / FASTMAIL_REPORT_TO (secrets) or -ReportFrom / -ReportTo;
  From defaults to an existing identity, To defaults to From. For local testing
  set FASTMAIL_MOCK_DIR (or -MockDir); set FASTMAIL_MOCK_OUTBOX to capture the
  emailed report to a file.

.EXAMPLE
  ./Add-FromAddress.ps1 -Address new-alias@example.com -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [string[]]$Address,

    [string]$Name,

    [string]$ReportFrom,
    [string]$ReportTo,

    [string]$MockDir
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($MockDir) { $env:FASTMAIL_MOCK_DIR = $MockDir }
Import-Module (Join-Path $PSScriptRoot 'FastmailJmap.psm1') -Force

$token = Get-FastmailToken
$session = New-JmapSession -Token $token

$identities = Get-FastmailIdentities -Session $session
$existing = @($identities | ForEach-Object { $_.email })

$displayName = $Name
if (-not $PSBoundParameters.ContainsKey('Name')) {
    $named = $identities | Where-Object { (Test-HasKey $_ 'name') -and $_.name } | Select-Object -First 1
    if ($named) { $displayName = $named.name }
}

$mailboxes = Get-FastmailMailboxes -Session $session
$sentId = Get-SentMailboxId -Session $session -Mailboxes $mailboxes

# ShouldProcess returns $false under -WhatIf, $true otherwise.
$apply = $PSCmdlet.ShouldProcess("Fastmail account", "add From identities")

$results = Add-FastmailIdentity -Session $session -Addresses $Address -Name $displayName `
    -SentId $sentId -ExistingEmails $existing -Apply:$apply

$modeText = if ($apply) { 'applied' } else { 'dry run' }
$report = New-IdentityReport -Existing $existing -Results $results -WhatIf:(-not $apply) `
    -Title 'fastmail-actions: add-from-address'

$from = if ($ReportFrom) { $ReportFrom } elseif ($env:FASTMAIL_REPORT_FROM) { $env:FASTMAIL_REPORT_FROM } else { @($existing)[0] }
$to = if ($ReportTo) { $ReportTo } elseif ($env:FASTMAIL_REPORT_TO) { $env:FASTMAIL_REPORT_TO } else { $from }
if (-not $from) { throw "no report From address: set FASTMAIL_REPORT_FROM (or -ReportFrom)." }

Send-FastmailReport -Session $session -From $from -To $to `
    -Subject "fastmail-actions: add-from-address ($modeText)" -BodyText $report `
    -Identities $identities -Mailboxes $mailboxes | Out-Null

Write-Host "add-from-address complete (mode: $modeText). Report emailed to the configured recipient."
if ($results | Where-Object { $_.Status -eq 'failed' }) { exit 1 }
