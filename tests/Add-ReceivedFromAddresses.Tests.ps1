#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  End-to-end tests of Add-ReceivedFromAddresses.ps1 in mock mode. The fixture is
  designed so exactly two aliases survive all three stages: alias1@example.net
  and alias4@example.net. Verifies the funnel + candidates + delta are EMAILED
  (captured to the mock outbox) and that no address/scan total leaks to stdout.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Script = Join-Path $script:Root 'scripts/Add-ReceivedFromAddresses.ps1'
    $script:MockDir = Join-Path $script:Root 'mocks'

    function Invoke-Discover {
        # MinDate defaults to a very old date so all fixture messages are in scope.
        param([switch]$WhatIf, [string]$MinDate = '2000-01-01')
        $outbox = Join-Path ([System.IO.Path]::GetTempPath()) ("od-{0}.jsonl" -f ([guid]::NewGuid().ToString('N')))
        $stdout = & pwsh -NoProfile -Command {
            param($ScriptPath, $MockDir, $Outbox, $DoWhatIf, $MinDate)
            $ErrorActionPreference = 'Stop'
            $env:FASTMAIL_MOCK_OUTBOX = $Outbox
            $env:FASTMAIL_REPORT_FROM = 'reports@example.net'
            $env:FASTMAIL_REPORT_TO = 'reports@example.net'
            $splat = @{ MockDir = $MockDir; MinDate = [datetime]$MinDate }
            if ($DoWhatIf -eq 'true') { $splat['WhatIf'] = $true }
            & $ScriptPath @splat *>&1 | Out-String
        } -args $script:Script, $script:MockDir, $outbox, ([string]$WhatIf.IsPresent).ToLower(), $MinDate
        $body = if (Test-Path $outbox) { (Get-Content -Raw $outbox | ConvertFrom-Json).body } else { $null }
        Remove-Item $outbox -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Stdout = ($stdout | Out-String); ReportBody = $body }
    }
}

Describe 'Add-ReceivedFromAddresses.ps1 (mock mode)' {
    It 'emails funnel counts, candidates, and delta; nothing sensitive on stdout' {
        $res = Invoke-Discover -WhatIf
        $res.ReportBody | Should -Match 'stage 1: 5 distinct'
        $res.ReportBody | Should -Match 'stage 2: 3 have a known correspondent'
        $res.ReportBody | Should -Match 'stage 3: 2 are not already identities'
        $res.ReportBody | Should -Match 'DRY RUN'
        $res.ReportBody | Should -Match 'alias1@example\.net'
        $res.ReportBody | Should -Match 'alias4@example\.net'
        # scan totals and addresses must NOT be on stdout
        $res.Stdout | Should -Match 'Report emailed'
        $res.Stdout | Should -Not -Match '@example\.'
        $res.Stdout | Should -Not -Match 'scanned'
        $res.Stdout | Should -Not -Match 'stage '
    }

    It 'does not propose already-existing or one-way aliases' {
        $res = Invoke-Discover -WhatIf
        $res.ReportBody | Should -Not -Match 'alias2@example\.net'
        $res.ReportBody | Should -Not -Match 'alias3@example\.net'
    }

    It 'applied: emails a report with newly added aliases' {
        $res = Invoke-Discover
        $res.ReportBody | Should -Match 'APPLIED'
        $res.ReportBody | Should -Match 'alias1@example\.net'
        $res.ReportBody | Should -Match 'alias4@example\.net'
        $res.Stdout | Should -Not -Match '@example\.'
    }

    It 'a min-date filter drops aliases only seen before it' {
        # e2/e5 are dated 2019; a 2023 cutoff removes them, so alias4 (only ever
        # seen via the 2019 message e5) is no longer a candidate.
        $res = Invoke-Discover -WhatIf -MinDate '2023-01-01'
        $res.ReportBody | Should -Match 'date window: messages on or after 2023-01-01'
        $res.ReportBody | Should -Match 'stage 1: 3 distinct'
        $res.ReportBody | Should -Match 'stage 3: 1 are not already identities'
        $res.ReportBody | Should -Match 'alias1@example\.net'
        $res.ReportBody | Should -Not -Match 'alias4@example\.net'
    }
}
