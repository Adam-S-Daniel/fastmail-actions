#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  End-to-end tests of Add-FromAddress.ps1 in mock mode. Verifies the report is
  EMAILED (captured to the mock outbox) with the required sections, and that no
  address leaks to stdout.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Script = Join-Path $script:Root 'scripts/Add-FromAddress.ps1'
    $script:MockDir = Join-Path $script:Root 'mocks'

    function Invoke-AddFrom {
        param([string[]]$AddressArg, [switch]$WhatIf)
        $outbox = Join-Path ([System.IO.Path]::GetTempPath()) ("of-{0}.jsonl" -f ([guid]::NewGuid().ToString('N')))
        $stdout = & pwsh -NoProfile -Command {
            param($ScriptPath, $MockDir, $Outbox, $Addr, $DoWhatIf)
            $ErrorActionPreference = 'Stop'
            $env:FASTMAIL_MOCK_OUTBOX = $Outbox
            $env:FASTMAIL_REPORT_FROM = 'reports@example.net'
            $env:FASTMAIL_REPORT_TO = 'reports@example.net'
            $splat = @{ Address = ($Addr -split ','); MockDir = $MockDir }
            if ($DoWhatIf -eq 'true') { $splat['WhatIf'] = $true }
            & $ScriptPath @splat *>&1 | Out-String
        } -args $script:Script, $script:MockDir, $outbox, ($AddressArg -join ','), ([string]$WhatIf.IsPresent).ToLower()
        $body = if (Test-Path $outbox) { (Get-Content -Raw $outbox | ConvertFrom-Json).body } else { $null }
        Remove-Item $outbox -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Stdout = ($stdout | Out-String); ReportBody = $body }
    }
}

Describe 'Add-FromAddress.ps1 (mock mode)' {
    It 'dry run: emails a report listing pre-existing and would-add; stdout has no addresses' {
        $res = Invoke-AddFrom -AddressArg 'brand-new@example.net' -WhatIf
        $res.ReportBody | Should -Match 'DRY RUN'
        $res.ReportBody | Should -Match 'Pre-existing From addresses'
        $res.ReportBody | Should -Match 'adam@example\.net'
        $res.ReportBody | Should -Match 'Would be added'
        $res.ReportBody | Should -Match 'brand-new@example\.net'
        # stdout must not leak any address
        $res.Stdout | Should -Match 'Report emailed'
        $res.Stdout | Should -Not -Match '@example\.'
    }

    It 'applied: emails a report with newly added address; stdout has no addresses' {
        $res = Invoke-AddFrom -AddressArg 'brand-new@example.net'
        $res.ReportBody | Should -Match 'APPLIED'
        $res.ReportBody | Should -Match 'Added'
        $res.ReportBody | Should -Match 'brand-new@example\.net'
        $res.Stdout | Should -Not -Match '@example\.'
    }

    It 'skips an address that is already an identity (in the emailed report)' {
        $res = Invoke-AddFrom -AddressArg 'adam@example.net,brand-new@example.net'
        $res.ReportBody | Should -Match 'Skipped'
        $res.ReportBody | Should -Match 'adam@example\.net'
        $res.Stdout | Should -Not -Match '@example\.'
    }
}
