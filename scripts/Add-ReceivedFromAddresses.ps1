#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Discover which of a Fastmail account's own alias addresses are worth sending
  from, and add them as "From" identities.

.DESCRIPTION
  Three internal stages (pure, unit-tested functions in FastmailJmap.psm1):
    1. Every distinct X-Delivered-To address across all messages.
    2. Keep only aliases with a known correspondent (a sender you have also
       emailed), dropping one-way addresses.
    3. Drop any already set up as identities.
  Survivors are added via the same Identity/set call as Add-FromAddress.

  PRIVACY: the report (funnel counts, candidate addresses, correspondents,
  pre-existing identities, and mailbox scan totals) is emailed to the account,
  from the account, over JMAP EmailSubmission — it is NEVER printed or logged.
  stdout gets only a non-identifying confirmation.

  Follows -WhatIf conventions: with -WhatIf it reports what WOULD be added and
  makes no changes; without it, it makes the changes and reports what was added.

  Auth: FASTMAIL_API_TOKEN. Report routing: FASTMAIL_REPORT_FROM /
  FASTMAIL_REPORT_TO (secrets) or -ReportFrom / -ReportTo.

.EXAMPLE
  ./Add-ReceivedFromAddresses.ps1 -WhatIf
  ./Add-ReceivedFromAddresses.ps1            # applies
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Name,

    [int]$Max,

    # Only consider messages sent/received on or after this date. Defaults to
    # -SinceDays days before now (730 = ~2 years) so discovery reflects aliases
    # you have used recently rather than your entire history.
    [datetime]$MinDate,
    [int]$SinceDays = 730,

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

# Date window: consider only messages on or after this instant (JMAP 'after'
# filters on receivedAt, which is the send time for Sent mail and the delivery
# time for received mail — "sent or received as appropriate").
$effectiveMinDate = if ($PSBoundParameters.ContainsKey('MinDate')) {
    $MinDate.ToUniversalTime()
} else {
    (Get-Date).ToUniversalTime().AddDays(-$SinceDays)
}
$afterStr = $effectiveMinDate.ToString("yyyy-MM-ddTHH:mm:ssZ")

# Stage 0: who you have written to (within the window).
$sentRecipients = @()
$sentCount = 0
if ($sentId) {
    $sentQ = Get-EmailId -Session $session -Filter @{ inMailbox = $sentId; after = $afterStr } -Max $null
    $sentCount = $sentQ.Ids.Count
    $sentEmails = Get-FastmailEmail -Session $session -Ids $sentQ.Ids -Properties 'to', 'cc', 'bcc'
    $sentRecipients = @(Get-SentRecipientAddress -Emails $sentEmails)
}

# Stages 1-3 (within the window).
$maxArg = if ($PSBoundParameters.ContainsKey('Max')) { $Max } else { $null }
$allQ = Get-EmailId -Session $session -Filter @{ after = $afterStr } -Max $maxArg
$allEmails = @(Get-FastmailEmail -Session $session -Ids $allQ.Ids -Properties 'from', (Get-DeliveredToProp))
$deliveredMap = Get-DeliveredMap -Emails $allEmails

$distinct = @($deliveredMap.Keys)
$known = @(Select-KnownCorrespondent -DeliveredMap $deliveredMap -SentRecipients $sentRecipients)
$new = @(Select-NewIdentity -Candidates $known -ExistingEmails $existing)

# All of this is personal data -> it goes into the emailed report, never stdout.
# Summary/funnel lines (shown near the top); candidate details (shown after the
# added list, per the report layout).
$summary = @()
$summary += "date window: messages on or after $($effectiveMinDate.ToString('yyyy-MM-dd')) (sent or received)"
$summary += "scanned $sentCount sent messages -> $($sentRecipients.Count) distinct recipients you have written to"
$summary += "scanned $($allEmails.Count) messages"
$summary += "stage 1: $($distinct.Count) distinct X-Delivered-To addresses"
$summary += "stage 2: $($known.Count) have a known correspondent"
$summary += "stage 3: $($new.Count) are not already identities"
if ($allQ.Truncated) {
    $summary += "WARNING: scan capped at -Max=$Max messages; results are a sample, not exhaustive."
}

$candidates = @()
foreach ($a in $new) {
    $why = @($deliveredMap[$a] | Where-Object { $sentRecipients -contains $_ } | Select-Object -First 3)
    $candidates += [pscustomobject]@{ Address = $a; Why = ($why -join ', ') }
}

$apply = $PSCmdlet.ShouldProcess("Fastmail account", "add discovered From identities")
$modeText = if ($apply) { 'applied' } else { 'dry run' }

if ($new.Count -gt 0) {
    $results = Add-FastmailIdentity -Session $session -Addresses $new -Name $displayName `
        -SentId $sentId -ExistingEmails $existing -Apply:$apply
} else {
    $results = @()
}

$runUrl = if ($env:GITHUB_RUN_ID -and $env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY) {
    "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
} else { $null }

$report = New-IdentityReport -Existing $existing -Results $results -WhatIf:(-not $apply) `
    -Title 'fastmail-actions: add-received-from-addresses' -RunUrl $runUrl `
    -SummaryLines $summary -CandidateDetails $candidates

$from = if ($ReportFrom) { $ReportFrom } elseif ($env:FASTMAIL_REPORT_FROM) { $env:FASTMAIL_REPORT_FROM } else { @($existing)[0] }
$to = if ($ReportTo) { $ReportTo } elseif ($env:FASTMAIL_REPORT_TO) { $env:FASTMAIL_REPORT_TO } else { $from }
if (-not $from) { throw "no report From address: set FASTMAIL_REPORT_FROM (or -ReportFrom)." }

Send-FastmailReport -Session $session -From $from -To $to `
    -Subject "fastmail-actions: add-received-from-addresses ($modeText)" -BodyText $report.Text -BodyHtml $report.Html `
    -Identities $identities -Mailboxes $mailboxes | Out-Null

Write-Host "add-received-from-addresses complete (mode: $modeText). Report emailed to the configured recipient."
if ($results | Where-Object { $_.Status -eq 'failed' }) { exit 1 }
