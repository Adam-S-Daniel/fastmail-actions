<#
.SYNOPSIS
  Shared Fastmail JMAP helpers for the fastmail-actions workflows.

  Talks to the Fastmail JMAP API with a bearer API token. When the environment
  variable FASTMAIL_MOCK_DIR is set, all network I/O is replaced by an in-memory
  fake JMAP server driven by <MockDir>/session.json and <MockDir>/fixture.json.

  PRIVACY: reports (which contain email addresses and other personal data) are
  never printed or written to logs by the workflows. New-IdentityReport builds
  the report as a string; Send-FastmailReport emails it to the account, from the
  account, over JMAP EmailSubmission. Error messages are sanitized to a status
  code + JMAP error type so a failing API call cannot leak addresses into a
  public run log.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:SessionUrl = 'https://api.fastmail.com/jmap/session'
$script:Using = @(
    'urn:ietf:params:jmap:core',
    'urn:ietf:params:jmap:mail',
    'urn:ietf:params:jmap:submission'
)
$script:DeliveredToProp = 'header:X-Delivered-To:asText:all'

# --- small helpers that work for both hashtables (mock inputs) and
#     PSCustomObjects (parsed JSON responses) ---

function Test-HasKey {
    param($Object, [string]$Key)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Key) }
    return [bool]$Object.PSObject.Properties[$Key]
}

function Get-Prop {
    param($Object, [string]$Key)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Key)) { return $Object[$Key] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Key]
    if ($p) { return $p.Value }
    return $null
}

function Get-DeliveredToProp { return $script:DeliveredToProp }

function Get-FastmailMockDir {
    if ($env:FASTMAIL_MOCK_DIR) { return $env:FASTMAIL_MOCK_DIR }
    return $null
}

# --- auth ---

function Get-FastmailToken {
    <#
      Resolves the API token from, in order: FASTMAIL_API_TOKEN (the GitHub
      secret name; also Fastmail's own term), FASTMAIL_TOKEN_CMD (a command that
      prints the token), then ~/.fastmail_token. In mock mode a token is not
      required.
    #>
    $v = [Environment]::GetEnvironmentVariable('FASTMAIL_API_TOKEN')
    if ($v) { return $v.Trim() }
    if ($env:FASTMAIL_TOKEN_CMD) {
        $out = Invoke-Expression $env:FASTMAIL_TOKEN_CMD
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "FASTMAIL_TOKEN_CMD failed (exit $LASTEXITCODE)"
        }
        $tok = ($out | Out-String).Trim()
        if ($tok) { return $tok }
    }
    $path = Join-Path $HOME '.fastmail_token'
    if (Test-Path $path) {
        $tok = (Get-Content -Raw $path).Trim()
        if ($tok) { return $tok }
    }
    if (Get-FastmailMockDir) { return 'mock-token' }
    throw "no token: set FASTMAIL_API_TOKEN, or FASTMAIL_TOKEN_CMD (a command that prints the token), or write the token to ~/.fastmail_token"
}

# --- sanitized error surfacing (never echo a response body: it may contain
#     addresses) ---

function Get-SafeHttpError {
    param($ErrorRecord, [string]$Context)
    $code = $null
    try { $code = [int]$ErrorRecord.Exception.Response.StatusCode } catch {}
    $type = $null
    $body = $null
    try { $body = $ErrorRecord.ErrorDetails.Message } catch {}
    if ($body) {
        try {
            $j = $body | ConvertFrom-Json
            # Only the machine-readable 'type' URN is safe to surface; 'detail'
            # and 'title' can quote an address.
            $type = Get-Prop $j 'type'
        } catch {}
    }
    $m = "$Context failed"
    if ($code) { $m += " (HTTP $code)" }
    if ($type) { $m += " [$type]" }
    return $m
}

# --- session + transport ---

function New-JmapSession {
    param([string]$Token)
    $mock = Get-FastmailMockDir
    if ($mock) {
        $session = Get-Content -Raw (Join-Path $mock 'session.json') | ConvertFrom-Json
    } else {
        $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
        try {
            # No redirects: PowerShell would forward the bearer token across a
            # redirect to an attacker-chosen host.
            $session = Invoke-RestMethod -Uri $script:SessionUrl -Headers $headers -Method Get -MaximumRedirection 0
        } catch {
            throw (Get-SafeHttpError -ErrorRecord $_ -Context 'Fastmail JMAP session request')
        }
        # The token is POSTed to session.apiUrl next; refuse a non-HTTPS endpoint.
        if ([string]$session.apiUrl -notmatch '^https://') {
            throw "refusing to send the API token to a non-HTTPS JMAP endpoint"
        }
    }
    $accountId = $session.primaryAccounts.'urn:ietf:params:jmap:mail'
    $maxGet = 500
    $core = Get-Prop $session.capabilities 'urn:ietf:params:jmap:core'
    $m = Get-Prop $core 'maxObjectsInGet'
    if ($m) { $maxGet = [Math]::Min([int]$m, 500) }
    return [pscustomobject]@{
        Token     = $Token
        ApiUrl    = $session.apiUrl
        AccountId = $accountId
        MaxGet    = $maxGet
    }
}

function Invoke-Jmap {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$MethodCalls
    )
    $mock = Get-FastmailMockDir
    if ($mock) { return Invoke-JmapMock -Session $Session -MethodCalls $MethodCalls -MockDir $mock }
    $payload = @{ using = $script:Using; methodCalls = $MethodCalls }
    $headers = @{
        Authorization  = "Bearer $($Session.Token)"
        Accept         = 'application/json'
        'Content-Type' = 'application/json'
    }
    try {
        # Serialize inside the try so a serialization error (the payload can hold
        # report addresses) is reduced to a sanitized message, not printed raw.
        $body = $payload | ConvertTo-Json -Depth 20
        $resp = Invoke-RestMethod -Uri $Session.ApiUrl -Headers $headers -Method Post -Body $body
    } catch {
        throw (Get-SafeHttpError -ErrorRecord $_ -Context 'Fastmail JMAP request')
    }
    # Comma prevents PowerShell from unwrapping a single-element response array.
    return , @($resp.methodResponses)
}

function Invoke-JmapMock {
    <#
      An in-memory fake JMAP server. Honors the method calls the scripts make
      (Identity/get, Mailbox/get, Email/query, Email/get, Identity/set, Email/set,
      EmailSubmission/set) against <MockDir>/fixture.json, then round-trips the
      result through JSON so callers get PSCustomObjects/arrays like a real
      response. On Email/set it records the outgoing message to
      $env:FASTMAIL_MOCK_OUTBOX (one JSON object per line) so tests can assert the
      report was emailed rather than logged.
    #>
    param($Session, $MethodCalls, $MockDir)
    $fixture = Get-Content -Raw (Join-Path $MockDir 'fixture.json') | ConvertFrom-Json
    $responses = @()
    foreach ($mc in $MethodCalls) {
        $name = $mc[0]
        $callArgs = $mc[1]
        $callId = $mc[2]
        switch ($name) {
            'Identity/get' {
                $responses += , @($name, @{ accountId = $Session.AccountId; list = @($fixture.identities) }, $callId)
            }
            'Mailbox/get' {
                $responses += , @($name, @{ accountId = $Session.AccountId; list = @($fixture.mailboxes) }, $callId)
            }
            'Email/query' {
                $filter = Get-Prop $callArgs 'filter'
                $inMailbox = if ($filter) { Get-Prop $filter 'inMailbox' } else { $null }
                $after = if ($filter) { Get-Prop $filter 'after' } else { $null }
                if ($inMailbox) {
                    $sel = @($fixture.emails | Where-Object { $_._mailbox -eq $inMailbox })
                } else {
                    $sel = @($fixture.emails)
                }
                if ($after) {
                    $style = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
                    $afterDt = [datetime]::Parse($after, [System.Globalization.CultureInfo]::InvariantCulture, $style)
                    $sel = @($sel | Where-Object {
                            if (-not $_.PSObject.Properties['receivedAt']) { $true }
                            else { ([datetime]::Parse($_.receivedAt, [System.Globalization.CultureInfo]::InvariantCulture, $style)) -ge $afterDt }
                        })
                }
                $ids = @($sel | ForEach-Object { $_.id })
                $responses += , @($name, @{ accountId = $Session.AccountId; ids = $ids; total = $ids.Count; position = 0; collapseThreads = $false }, $callId)
            }
            'Email/get' {
                $ids = @(Get-Prop $callArgs 'ids')
                $props = @(Get-Prop $callArgs 'properties')
                $list = @()
                foreach ($id in $ids) {
                    $e = $fixture.emails | Where-Object { $_.id -eq $id } | Select-Object -First 1
                    if (-not $e) { continue }
                    $obj = @{ id = $id }
                    foreach ($p in $props) {
                        if ($e.PSObject.Properties[$p]) { $obj[$p] = $e.$p }
                    }
                    $list += , $obj
                }
                $responses += , @($name, @{ accountId = $Session.AccountId; list = $list }, $callId)
            }
            'Identity/set' {
                $create = Get-Prop $callArgs 'create'
                $created = @{}
                if ($create) {
                    $keys = if ($create -is [System.Collections.IDictionary]) { $create.Keys } else { $create.PSObject.Properties.Name }
                    foreach ($k in $keys) {
                        $created[$k] = @{ id = "mock-id-$k"; verificationState = 'autoverified' }
                    }
                }
                $responses += , @($name, @{ accountId = $Session.AccountId; created = $created; notCreated = @{} }, $callId)
            }
            'Email/set' {
                $create = Get-Prop $callArgs 'create'
                $created = @{}
                if ($create) {
                    $keys = if ($create -is [System.Collections.IDictionary]) { $create.Keys } else { $create.PSObject.Properties.Name }
                    foreach ($k in $keys) {
                        $created[$k] = @{ id = "mock-email-$k"; blobId = "mock-blob-$k"; threadId = "mock-thread-$k"; size = 0 }
                        if ($env:FASTMAIL_MOCK_OUTBOX) {
                            $obj = if ($create -is [System.Collections.IDictionary]) { $create[$k] } else { $create.$k }
                            $fromList = @(Get-Prop $obj 'from'); $toList = @(Get-Prop $obj 'to')
                            $bodyValues = Get-Prop $obj 'bodyValues'
                            $textPart = if ($bodyValues) { Get-Prop $bodyValues 'text' } else { $null }
                            $htmlPart = if ($bodyValues) { Get-Prop $bodyValues 'html' } else { $null }
                            $record = [ordered]@{
                                from    = if ($fromList.Count) { Get-Prop $fromList[0] 'email' } else { $null }
                                to      = if ($toList.Count) { Get-Prop $toList[0] 'email' } else { $null }
                                subject = Get-Prop $obj 'subject'
                                body    = if ($textPart) { Get-Prop $textPart 'value' } else { $null }
                                html    = if ($htmlPart) { Get-Prop $htmlPart 'value' } else { $null }
                            }
                            Add-Content -Path $env:FASTMAIL_MOCK_OUTBOX -Value ($record | ConvertTo-Json -Depth 10 -Compress)
                        }
                    }
                }
                $responses += , @($name, @{ accountId = $Session.AccountId; created = $created; notCreated = @{} }, $callId)
            }
            'EmailSubmission/set' {
                $create = Get-Prop $callArgs 'create'
                $created = @{}
                if ($create) {
                    $keys = if ($create -is [System.Collections.IDictionary]) { $create.Keys } else { $create.PSObject.Properties.Name }
                    foreach ($k in $keys) { $created[$k] = @{ id = "mock-sub-$k" } }
                }
                $responses += , @($name, @{ accountId = $Session.AccountId; created = $created; notCreated = @{} }, $callId)
            }
            default {
                throw "Invoke-JmapMock: unhandled method '$name'"
            }
        }
    }
    $parsed = @($responses | ConvertTo-Json -Depth 20 -AsArray | ConvertFrom-Json)
    # Comma prevents PowerShell from unwrapping a single-element response array.
    return , $parsed
}

# --- typed JMAP reads ---

function Get-FastmailIdentities {
    param($Session)
    $resp = Invoke-Jmap -Session $Session -MethodCalls @(, @('Identity/get', @{ accountId = $Session.AccountId; ids = $null }, '0'))
    return @($resp[0][1].list)
}

function Get-FastmailMailboxes {
    param($Session)
    $resp = Invoke-Jmap -Session $Session -MethodCalls @(, @('Mailbox/get', @{ accountId = $Session.AccountId; properties = @('id', 'role', 'name') }, '0'))
    return @($resp[0][1].list)
}

function Get-MailboxIdByRole {
    param($Session, [string]$Role, $Mailboxes)
    if (-not $Mailboxes) { $Mailboxes = Get-FastmailMailboxes -Session $Session }
    foreach ($mb in @($Mailboxes)) {
        if ((Test-HasKey $mb 'role') -and $mb.role -eq $Role) { return $mb.id }
    }
    return $null
}

function Get-SentMailboxId {
    param($Session, $Mailboxes)
    return Get-MailboxIdByRole -Session $Session -Role 'sent' -Mailboxes $Mailboxes
}

function Get-IdentityIdForEmail {
    param($Identities, [string]$Email)
    $target = $Email.ToLowerInvariant()
    foreach ($i in @($Identities)) {
        $e = Get-Prop $i 'email'
        if ($e -and ($e.ToLowerInvariant() -eq $target)) { return $i.id }
    }
    return $null
}

function Get-EmailId {
    param($Session, $Filter, $Max)
    if ($null -ne $Max) {
        $Max = [int]$Max
        if ($Max -lt 1) { throw "Max must be a positive integer." }
    }
    $ids = New-Object System.Collections.Generic.List[string]
    $position = 0
    $limit = $Session.MaxGet
    while ($true) {
        $q = @{
            accountId       = $Session.AccountId
            position        = $position
            limit           = $limit
            calculateTotal  = $true
            collapseThreads = $false
            sort            = @(, @{ property = 'receivedAt'; isAscending = $false })
        }
        if ($null -ne $Filter) { $q['filter'] = $Filter }
        $resp = Invoke-Jmap -Session $Session -MethodCalls @(, @('Email/query', $q, '0'))
        $res = $resp[0][1]
        $batch = @()
        if (Test-HasKey $res 'ids') { $batch = @($res.ids) }
        foreach ($b in $batch) { $ids.Add($b) }
        $total = if (Test-HasKey $res 'total') { [int]$res.total } else { $null }
        $position += $batch.Count
        if ($null -ne $Max -and $ids.Count -ge $Max) {
            return [pscustomobject]@{ Ids = @($ids[0..($Max - 1)]); Truncated = $true }
        }
        if ($batch.Count -eq 0 -or ($null -ne $total -and $position -ge $total)) { break }
    }
    return [pscustomobject]@{ Ids = @($ids); Truncated = $false }
}

function Get-FastmailEmail {
    param($Session, [string[]]$Ids, [string[]]$Properties)
    $out = @()
    if (-not $Ids -or $Ids.Count -eq 0) { return $out }
    $step = $Session.MaxGet
    for ($k = 0; $k -lt $Ids.Count; $k += $step) {
        $end = [Math]::Min($k + $step, $Ids.Count) - 1
        $chunk = @($Ids[$k..$end])
        $resp = Invoke-Jmap -Session $Session -MethodCalls @(, @('Email/get', @{ accountId = $Session.AccountId; ids = $chunk; properties = @($Properties) }, '0'))
        foreach ($e in @($resp[0][1].list)) { $out += $e }
    }
    return $out
}

# --- pure logic (unit-tested; no network) ---

function ConvertTo-NormAddr {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $v = $Value.Trim()
    $m = [regex]::Match($v, '<([^>]+)>')
    if ($m.Success) { $v = $m.Groups[1].Value }
    return $v.Trim().ToLowerInvariant()
}

function Get-DeliveredMap {
    <# emails: objects with 'from' and the X-Delivered-To header list.
       Returns a hashtable { delivered_to_addr = @(sender_addrs...) }. #>
    param($Emails)
    $prop = $script:DeliveredToProp
    $map = @{}
    foreach ($e in @($Emails)) {
        $senders = @()
        if ($e.PSObject.Properties['from']) {
            foreach ($f in @($e.from)) {
                if ($null -ne $f) {
                    $a = ConvertTo-NormAddr (Get-Prop $f 'email')
                    if ($a) { $senders += $a }
                }
            }
        }
        $dtoList = @()
        if ($e.PSObject.Properties[$prop]) { $dtoList = @($e.$prop) }
        foreach ($raw in $dtoList) {
            $dto = ConvertTo-NormAddr $raw
            if ($dto) {
                if (-not $map.ContainsKey($dto)) { $map[$dto] = [System.Collections.Generic.HashSet[string]]::new() }
                foreach ($s in $senders) { [void]$map[$dto].Add($s) }
            }
        }
    }
    $out = @{}
    foreach ($k in $map.Keys) { $out[$k] = @($map[$k] | Sort-Object) }
    return $out
}

function Get-SentRecipientAddress {
    <# Every address you have sent to (to/cc/bcc across your Sent mail). #>
    param($Emails)
    $set = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($e in @($Emails)) {
        foreach ($field in 'to', 'cc', 'bcc') {
            if ($e.PSObject.Properties[$field]) {
                foreach ($r in @($e.$field)) {
                    if ($null -ne $r) {
                        $a = ConvertTo-NormAddr (Get-Prop $r 'email')
                        if ($a) { [void]$set.Add($a) }
                    }
                }
            }
        }
    }
    return @($set | Sort-Object)
}

function Select-KnownCorrespondent {
    <# Delivered-to addresses that received mail from at least one person you
       have also written to. #>
    param([hashtable]$DeliveredMap, $SentRecipients)
    $sent = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($s in @($SentRecipients)) { [void]$sent.Add($s) }
    $out = @()
    foreach ($k in $DeliveredMap.Keys) {
        foreach ($sender in @($DeliveredMap[$k])) {
            if ($sent.Contains($sender)) { $out += $k; break }
        }
    }
    return @($out | Sort-Object)
}

function Select-NewIdentity {
    <# Candidates that are not already sending identities, sorted. #>
    param($Candidates, $ExistingEmails)
    $existing = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($e in @($ExistingEmails)) { [void]$existing.Add(([string]$e).ToLowerInvariant()) }
    return @(@($Candidates) | Where-Object { -not $existing.Contains(([string]$_).ToLowerInvariant()) } | Sort-Object)
}

# --- the mutating operation ---

function Add-FastmailIdentity {
    <#
      Create a sending identity for each address not already present.
      Returns a list of [pscustomobject]@{ Address; Status; Detail } where Status
      is one of skipped / would-add / added / failed.
      With -Apply it performs the Identity/set; without it, reports would-add.
    #>
    param(
        $Session,
        [string[]]$Addresses,
        [string]$Name,
        [string]$SentId,
        $ExistingEmails,
        [switch]$Apply
    )
    $existing = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($x in @($ExistingEmails)) { [void]$existing.Add(([string]$x).ToLowerInvariant()) }
    $displayName = if ($Name) { $Name } else { '' }

    $results = @()
    $toCreate = [ordered]@{}
    $index = 0
    foreach ($addr in @($Addresses)) {
        if ($existing.Contains($addr.ToLowerInvariant())) {
            $results += [pscustomobject]@{ Address = $addr; Status = 'skipped'; Detail = 'already an identity' }
            continue
        }
        $obj = [ordered]@{
            email              = $addr
            name               = $displayName
            replyTo            = $null
            bcc                = $null
            textSignature      = ''
            htmlSignature      = ''
            showInCompose      = $true
            useForAutoReply    = $true
            mayDelete          = $true
            isAutoConfigured   = $false
            enableExternalSMTP = $false
        }
        if ($SentId) { $obj['saveSentToMailboxId'] = $SentId }
        $toCreate["$index"] = $obj
        $index++
    }

    if (-not $Apply) {
        foreach ($k in $toCreate.Keys) {
            $results += [pscustomobject]@{ Address = $toCreate[$k].email; Status = 'would-add'; Detail = '' }
        }
        return $results
    }

    if ($toCreate.Count -gt 0) {
        $resp = Invoke-Jmap -Session $Session -MethodCalls @(, @('Identity/set', @{ accountId = $Session.AccountId; create = $toCreate }, '0'))
        $setres = $resp[0][1]
        $created = Get-Prop $setres 'created'
        $notCreated = Get-Prop $setres 'notCreated'
        foreach ($k in $toCreate.Keys) {
            $email = $toCreate[$k].email
            if (Test-HasKey $created $k) {
                $info = Get-Prop $created $k
                $vs = Get-Prop $info 'verificationState'; if (-not $vs) { $vs = '?' }
                $id = Get-Prop $info 'id'; if (-not $id) { $id = '?' }
                $results += [pscustomobject]@{ Address = $email; Status = 'added'; Detail = "verification=$vs id=$id" }
            } elseif (Test-HasKey $notCreated $k) {
                $err = Get-Prop $notCreated $k
                $type = Get-Prop $err 'type'; if (-not $type) { $type = 'unknown error' }
                $results += [pscustomobject]@{ Address = $email; Status = 'failed'; Detail = $type }
            } else {
                $results += [pscustomobject]@{ Address = $email; Status = 'failed'; Detail = 'no result returned' }
            }
        }
    }
    return $results
}

# --- reporting: BUILD the email body (never printed by the workflows) ---

function ConvertTo-HtmlEncoded {
    param([string]$Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function New-IdentityReport {
    <#
      Returns [pscustomobject]@{ Text; Html } — the email body in both plain text
      and polished HTML. Section order: run link, mode, summary (discover funnel),
      the added / would-add list, candidate details (discover), pre-existing
      addresses, then skipped/failed. Emailed by Send-FastmailReport, never logged.
    #>
    param(
        [string[]]$Existing,
        $Results,
        [switch]$WhatIf,
        [string]$Title = 'Fastmail From addresses',
        [string]$RunUrl,
        [string[]]$SummaryLines,      # discover funnel/date lines
        $CandidateDetails             # discover: @{ Address; Why } list
    )
    $mode = if ($WhatIf) { 'DRY RUN (whatif) - no changes made' } else { 'APPLIED - changes committed' }
    $existingSorted = @($Existing | Sort-Object)
    $added = @($Results | Where-Object { $_.Status -in 'added', 'would-add' })
    $skipped = @($Results | Where-Object { $_.Status -eq 'skipped' })
    $failed = @($Results | Where-Object { $_.Status -eq 'failed' })
    $candidates = @($CandidateDetails | Where-Object { $null -ne $_ })
    $addedVerb = if ($WhatIf) { 'Would be added' } else { 'Added' }

    # ---- plain-text alternative ----
    $t = @()
    if ($RunUrl) { $t += "Run: $RunUrl"; $t += "" }
    $t += $Title
    $t += ('=' * $Title.Length)
    $t += ""
    $t += "Mode: $mode"
    $t += ""
    if ($SummaryLines) { $t += $SummaryLines; $t += "" }
    $t += "${addedVerb} ($($added.Count)):"
    if ($added.Count) {
        foreach ($r in $added) {
            $suffix = if ($r.Detail) { "  ($($r.Detail))" } else { '' }
            $t += "  - $($r.Address)$suffix"
        }
    } else { $t += "  (none)" }
    if ($candidates.Count) {
        $t += ""
        $t += "Qualifying correspondents:"
        foreach ($c in $candidates) { $t += "  - $($c.Address)   (correspondent: $($c.Why))" }
    }
    $t += ""
    $t += "Pre-existing From addresses ($($existingSorted.Count)):"
    if ($existingSorted.Count) { foreach ($e in $existingSorted) { $t += "  - $e" } } else { $t += "  (none)" }
    if ($skipped.Count) {
        $t += ""
        $t += "Skipped - already present ($($skipped.Count)):"
        foreach ($r in $skipped) { $t += "  - $($r.Address)" }
    }
    if ($failed.Count) {
        $t += ""
        $t += "Failed ($($failed.Count)):"
        foreach ($r in $failed) { $t += "  - $($r.Address) ($($r.Detail))" }
    }
    $text = ($t -join "`n")

    # ---- HTML alternative (inline styles for email clients) ----
    $badgeStyle = if ($WhatIf) { 'background:#ddf4ff;color:#0969da;' } else { 'background:#dafbe1;color:#1a7f37;' }
    $badgeText = if ($WhatIf) { 'DRY RUN' } else { 'APPLIED' }
    $h = New-Object System.Text.StringBuilder
    [void]$h.Append('<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#1f2328;max-width:640px;margin:0;line-height:1.5;font-size:14px;">')
    [void]$h.Append("<h2 style=""margin:0 0 8px;font-size:20px;"">$(ConvertTo-HtmlEncoded $Title)</h2>")
    [void]$h.Append('<div style="margin:0 0 16px;">')
    [void]$h.Append("<span style=""display:inline-block;padding:2px 10px;border-radius:12px;font-size:12px;font-weight:600;$badgeStyle"">$badgeText</span>")
    if ($RunUrl) {
        [void]$h.Append("<a href=""$(ConvertTo-HtmlEncoded $RunUrl)"" style=""margin-left:12px;font-size:13px;color:#0969da;text-decoration:none;"">View workflow run &#8599;</a>")
    }
    [void]$h.Append('</div>')

    if ($SummaryLines) {
        [void]$h.Append('<div style="background:#f6f8fa;border:1px solid #d0d7de;border-radius:6px;padding:10px 14px;font-size:13px;color:#57606a;margin:0 0 16px;">')
        foreach ($line in $SummaryLines) { if ($line) { [void]$h.Append("<div>$(ConvertTo-HtmlEncoded $line)</div>") } }
        [void]$h.Append('</div>')
    }

    [void]$h.Append("<h3 style=""font-size:15px;margin:16px 0 6px;"">$addedVerb <span style=""color:#8b949e;font-weight:400;"">($($added.Count))</span></h3>")
    if ($added.Count) {
        [void]$h.Append('<ul style="margin:0;padding-left:20px;">')
        foreach ($r in $added) {
            $detail = if ($r.Detail) { " <span style=""color:#8b949e;font-size:12px;"">$(ConvertTo-HtmlEncoded $r.Detail)</span>" } else { '' }
            [void]$h.Append("<li style=""margin:2px 0;""><code style=""background:#f6f8fa;padding:1px 5px;border-radius:4px;"">$(ConvertTo-HtmlEncoded $r.Address)</code>$detail</li>")
        }
        [void]$h.Append('</ul>')
    } else { [void]$h.Append('<p style="color:#8b949e;margin:0;">none</p>') }

    if ($candidates.Count) {
        [void]$h.Append('<h3 style="font-size:15px;margin:18px 0 6px;">Qualifying correspondents</h3>')
        [void]$h.Append('<table style="border-collapse:collapse;width:100%;font-size:13px;">')
        [void]$h.Append('<tr><th align="left" style="border-bottom:2px solid #d0d7de;padding:4px 8px;">Address</th><th align="left" style="border-bottom:2px solid #d0d7de;padding:4px 8px;">Qualifying correspondent(s)</th></tr>')
        foreach ($c in $candidates) {
            [void]$h.Append("<tr><td style=""border-bottom:1px solid #eaeef2;padding:4px 8px;""><code>$(ConvertTo-HtmlEncoded $c.Address)</code></td><td style=""border-bottom:1px solid #eaeef2;padding:4px 8px;color:#57606a;"">$(ConvertTo-HtmlEncoded $c.Why)</td></tr>")
        }
        [void]$h.Append('</table>')
    }

    [void]$h.Append("<h3 style=""font-size:15px;margin:18px 0 6px;"">Pre-existing From addresses <span style=""color:#8b949e;font-weight:400;"">($($existingSorted.Count))</span></h3>")
    if ($existingSorted.Count) {
        $escaped = @($existingSorted | ForEach-Object { ConvertTo-HtmlEncoded $_ })
        [void]$h.Append('<div style="font-size:12px;color:#57606a;background:#f6f8fa;border:1px solid #d0d7de;border-radius:6px;padding:10px 14px;word-break:break-word;">')
        [void]$h.Append(($escaped -join ' &middot; '))
        [void]$h.Append('</div>')
    } else { [void]$h.Append('<p style="color:#8b949e;margin:0;">none</p>') }

    if ($skipped.Count) {
        [void]$h.Append("<h3 style=""font-size:15px;margin:18px 0 6px;"">Skipped &mdash; already present <span style=""color:#8b949e;font-weight:400;"">($($skipped.Count))</span></h3>")
        [void]$h.Append('<ul style="margin:0;padding-left:20px;font-size:13px;color:#57606a;">')
        foreach ($r in $skipped) { [void]$h.Append("<li><code>$(ConvertTo-HtmlEncoded $r.Address)</code></li>") }
        [void]$h.Append('</ul>')
    }
    if ($failed.Count) {
        [void]$h.Append("<h3 style=""font-size:15px;margin:18px 0 6px;color:#cf222e;"">Failed <span style=""font-weight:400;"">($($failed.Count))</span></h3>")
        [void]$h.Append('<ul style="margin:0;padding-left:20px;font-size:13px;color:#cf222e;">')
        foreach ($r in $failed) { [void]$h.Append("<li><code>$(ConvertTo-HtmlEncoded $r.Address)</code> &mdash; $(ConvertTo-HtmlEncoded $r.Detail)</li>") }
        [void]$h.Append('</ul>')
    }

    [void]$h.Append('<p style="color:#8b949e;font-size:12px;margin-top:22px;border-top:1px solid #eaeef2;padding-top:10px;">Sent by fastmail-actions.</p>')
    [void]$h.Append('</div>')

    return [pscustomobject]@{ Text = $text; Html = $h.ToString() }
}

# --- send the report over JMAP EmailSubmission ---

function Send-FastmailReport {
    <#
      Email $BodyText to $To from $From over JMAP: create a draft, submit it, and
      (best effort) move the sent copy to Sent. Requires an existing sending
      identity whose address is $From. Returns $true on success; throws a
      sanitized error otherwise.
    #>
    param(
        $Session,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$BodyText,
        [string]$BodyHtml,
        $Identities,
        $Mailboxes
    )
    if (-not $Identities) { $Identities = Get-FastmailIdentities -Session $Session }
    $identityId = Get-IdentityIdForEmail -Identities $Identities -Email $From
    if (-not $identityId) {
        throw "cannot email report: no sending identity for the configured From address exists on this account (add it first with add-from-address)."
    }
    if (-not $Mailboxes) { $Mailboxes = Get-FastmailMailboxes -Session $Session }
    $draftsId = Get-MailboxIdByRole -Session $Session -Role 'drafts' -Mailboxes $Mailboxes
    $sentId = Get-MailboxIdByRole -Session $Session -Role 'sent' -Mailboxes $Mailboxes
    if (-not $draftsId) { throw "cannot email report: no Drafts mailbox found on this account." }

    # multipart/alternative: text + (optional) HTML.
    $email = [ordered]@{
        mailboxIds = @{ $draftsId = $true }
        keywords   = @{ '$draft' = $true; '$seen' = $true }
        from       = @(@{ email = $From })
        to         = @(@{ email = $To })
        subject    = $Subject
        bodyValues = @{ text = @{ value = $BodyText; charset = 'utf-8' } }
        textBody   = @(@{ partId = 'text'; type = 'text/plain' })
    }
    if ($BodyHtml) {
        $email['bodyValues']['html'] = @{ value = $BodyHtml; charset = 'utf-8' }
        $email['htmlBody'] = @(@{ partId = 'html'; type = 'text/html' })
    }

    $submission = [ordered]@{
        emailId    = '#draft'
        identityId = $identityId
        envelope   = @{ mailFrom = @{ email = $From }; rcptTo = @(@{ email = $To }) }
    }
    $submissionSet = @{ accountId = $Session.AccountId; create = @{ sub = $submission } }
    if ($sentId) {
        # On success, take it out of Drafts and file it in Sent.
        $submissionSet['onSuccessUpdateEmail'] = @{
            '#sub' = @{
                "mailboxIds/$draftsId" = $null
                "mailboxIds/$sentId"   = $true
                'keywords/$draft'      = $null
            }
        }
    }

    $calls = @(
        @('Email/set', @{ accountId = $Session.AccountId; create = @{ draft = $email } }, 'a'),
        @('EmailSubmission/set', $submissionSet, 'b')
    )
    $resp = Invoke-Jmap -Session $Session -MethodCalls $calls

    $subRes = $null
    foreach ($r in @($resp)) {
        if ($r[0] -eq 'EmailSubmission/set') { $subRes = $r[1]; break }
    }
    $created = if ($subRes) { Get-Prop $subRes 'created' } else { $null }
    if (-not (Test-HasKey $created 'sub')) {
        $type = 'unknown error'
        $nc = if ($subRes) { Get-Prop $subRes 'notCreated' } else { $null }
        if (Test-HasKey $nc 'sub') { $t = Get-Prop (Get-Prop $nc 'sub') 'type'; if ($t) { $type = $t } }
        throw "report email was not sent [$type]."
    }
    return $true
}

Export-ModuleMember -Function `
    Test-HasKey, Get-Prop, Get-DeliveredToProp, Get-FastmailMockDir, Get-SafeHttpError, `
    Get-FastmailToken, New-JmapSession, Invoke-Jmap, Invoke-JmapMock, `
    Get-FastmailIdentities, Get-FastmailMailboxes, Get-MailboxIdByRole, Get-SentMailboxId, `
    Get-IdentityIdForEmail, Get-EmailId, Get-FastmailEmail, `
    ConvertTo-NormAddr, Get-DeliveredMap, Get-SentRecipientAddress, `
    Select-KnownCorrespondent, Select-NewIdentity, Add-FastmailIdentity, `
    New-IdentityReport, Send-FastmailReport
