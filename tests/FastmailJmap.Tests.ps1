#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Unit tests for the pure discovery logic (mirrors the Python test_filters.py),
  plus mock-mode integration tests for the JMAP transport, identity reads,
  Add-FastmailIdentity, and Send-FastmailReport. Uses only example.* addresses.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $script:Root 'scripts/FastmailJmap.psm1'
    $script:MockDir = Join-Path $script:Root 'mocks'
    Import-Module $script:ModulePath -Force
    $script:DTO = Get-DeliveredToProp

    function New-Mail {
        param($FromAddr, [string[]]$DeliveredTo)
        $h = @{ $script:DTO = $DeliveredTo }
        if ($FromAddr) { $h['from'] = @(@{ email = $FromAddr }) } else { $h['from'] = @() }
        return [pscustomobject]$h
    }
}

Describe 'ConvertTo-NormAddr' {
    It 'lowercases a plain address' { ConvertTo-NormAddr 'Foo@Example.COM' | Should -Be 'foo@example.com' }
    It 'extracts the address from a display-name form' { ConvertTo-NormAddr 'Alice <Alice@Ex.com>' | Should -Be 'alice@ex.com' }
    It 'returns empty for null/empty' {
        ConvertTo-NormAddr $null | Should -Be ''
        ConvertTo-NormAddr '' | Should -Be ''
    }
}

Describe 'Get-DeliveredMap' {
    It 'groups senders per delivered-to address and lowercases' {
        $emails = @(
            (New-Mail 'Bob@Ex.com'   @('Alias1@Me.com')),
            (New-Mail 'carol@ex.com' @('alias1@me.com')),
            (New-Mail 'dave@ex.com'  @('Alias2@Me.com'))
        )
        $m = Get-DeliveredMap -Emails $emails
        @($m.Keys | Sort-Object) | Should -Be @('alias1@me.com', 'alias2@me.com')
        @($m['alias1@me.com']) | Should -Be @('bob@ex.com', 'carol@ex.com')
    }
    It 'ignores messages with no delivered-to' {
        (Get-DeliveredMap -Emails @((New-Mail $null @()))).Keys.Count | Should -Be 0
    }
}

Describe 'Get-SentRecipientAddress' {
    It 'collects to/cc/bcc and lowercases' {
        $sent = @([pscustomobject]@{ to = @(@{ email = 'A@ex.com' }); cc = @(@{ email = 'b@ex.com' }); bcc = @(@{ email = 'c@ex.com' }) })
        @(Get-SentRecipientAddress -Emails $sent) | Should -Be @('a@ex.com', 'b@ex.com', 'c@ex.com')
    }
}

Describe 'Select-KnownCorrespondent' {
    It 'keeps only aliases with at least one known sender' {
        $delivered = @{ 'alias1@me.com' = @('bob@ex.com', 'news@spam.example'); 'alias2@me.com' = @('news@spam.example') }
        @(Select-KnownCorrespondent -DeliveredMap $delivered -SentRecipients @('bob@ex.com')) | Should -Be @('alias1@me.com')
    }
}

Describe 'Select-NewIdentity' {
    It 'drops existing (case-insensitively) and sorts' {
        @(Select-NewIdentity -Candidates @('b@me.com', 'a@me.com', 'c@me.com') -ExistingEmails @('C@Me.com')) | Should -Be @('a@me.com', 'b@me.com')
    }
}

Describe 'New-IdentityReport' {
    It 'lists pre-existing and would-add in dry-run text' {
        $r = @([pscustomobject]@{ Address = 'new@example.net'; Status = 'would-add'; Detail = '' })
        $text = New-IdentityReport -Existing @('a@example.net') -Results $r -WhatIf -Title 'T'
        $text | Should -Match 'DRY RUN'
        $text | Should -Match 'a@example\.net'
        $text | Should -Match 'Would be added'
        $text | Should -Match 'new@example\.net'
    }
}

Describe 'JMAP + reporting (mock mode)' {
    BeforeEach { $env:FASTMAIL_MOCK_DIR = $script:MockDir }
    AfterEach {
        Remove-Item Env:FASTMAIL_MOCK_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:FASTMAIL_MOCK_OUTBOX -ErrorAction SilentlyContinue
    }

    It 'builds a session and reads identities' {
        $s = New-JmapSession -Token (Get-FastmailToken)
        $s.AccountId | Should -Be 'acct-mock'
        @((Get-FastmailIdentities -Session $s) | ForEach-Object { $_.email }) | Should -Contain 'adam@example.net'
    }

    It 'resolves mailbox roles and identity ids' {
        $s = New-JmapSession -Token (Get-FastmailToken)
        Get-MailboxIdByRole -Session $s -Role 'sent' | Should -Be 'mb-sent'
        Get-MailboxIdByRole -Session $s -Role 'drafts' | Should -Be 'mb-drafts'
        $ids = Get-FastmailIdentities -Session $s
        Get-IdentityIdForEmail -Identities $ids -Email 'REPORTS@example.net' | Should -Be 'i3'
        Get-IdentityIdForEmail -Identities $ids -Email 'nope@example.net' | Should -BeNullOrEmpty
    }

    It 'adds a new identity when applied' {
        $s = New-JmapSession -Token (Get-FastmailToken)
        $existing = @((Get-FastmailIdentities -Session $s) | ForEach-Object { $_.email })
        $r = Add-FastmailIdentity -Session $s -Addresses @('brand-new@example.net') -Name 'X' -SentId 'mb-sent' -ExistingEmails $existing -Apply
        ($r | Where-Object Address -eq 'brand-new@example.net').Status | Should -Be 'added'
    }

    It 'emails a report and records it to the outbox' {
        $outbox = Join-Path ([System.IO.Path]::GetTempPath()) ("outbox-{0}.jsonl" -f ([guid]::NewGuid().ToString('N')))
        $env:FASTMAIL_MOCK_OUTBOX = $outbox
        try {
            $s = New-JmapSession -Token (Get-FastmailToken)
            Send-FastmailReport -Session $s -From 'reports@example.net' -To 'reports@example.net' `
                -Subject 'test-subject' -BodyText 'body-with alias9@example.net' | Should -BeTrue
            Test-Path $outbox | Should -BeTrue
            $rec = Get-Content -Raw $outbox | ConvertFrom-Json
            $rec.from | Should -Be 'reports@example.net'
            $rec.subject | Should -Be 'test-subject'
            $rec.body | Should -Match 'alias9@example\.net'
        } finally { Remove-Item $outbox -ErrorAction SilentlyContinue }
    }

    It 'throws (without leaking) when the From identity does not exist' {
        $s = New-JmapSession -Token (Get-FastmailToken)
        { Send-FastmailReport -Session $s -From 'missing@example.net' -To 'missing@example.net' -Subject 's' -BodyText 'b' } |
            Should -Throw -ExpectedMessage '*no sending identity*'
    }
}
