#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  End-to-end tests of Send-SelfAlert.ps1 in mock mode. Each case runs the
  script in a child pwsh with its own env and mock outbox, so nothing leaks
  between cases and no network is touched. Addresses are the example.net
  identities in mocks/fixture.json.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Script = Join-Path $script:Root 'scripts/Send-SelfAlert.ps1'
    $script:MockDir = Join-Path $script:Root 'mocks'

    function Invoke-SelfAlert {
        param(
            [string]$SubjectArg = 'Disk space low',
            [string]$BodyArg = 'The nightly job reported low disk space.',
            [string]$AlertFrom = 'reports@example.net',
            [string]$AlertTo = 'adam@example.net'
        )
        $outbox = Join-Path ([System.IO.Path]::GetTempPath()) ("sa-{0}.jsonl" -f ([guid]::NewGuid().ToString('N')))
        $result = & pwsh -NoProfile -Command {
            param($ScriptPath, $MockDir, $Outbox, $From, $To, $Subj, $Bod)
            $env:FASTMAIL_MOCK_DIR = $MockDir
            $env:FASTMAIL_MOCK_OUTBOX = $Outbox
            if ($From) { $env:SELF_ALERT_FROM = $From } else { Remove-Item Env:SELF_ALERT_FROM -ErrorAction SilentlyContinue }
            if ($To) { $env:SELF_ALERT_TO = $To } else { Remove-Item Env:SELF_ALERT_TO -ErrorAction SilentlyContinue }
            $code = 0
            $out = try { & $ScriptPath -Subject $Subj -Body $Bod *>&1 | Out-String } catch { $code = 1; $_.Exception.Message }
            [pscustomobject]@{ ExitCode = $code; Output = [string]$out }
        } -args $script:Script, $script:MockDir, $outbox, $AlertFrom, $AlertTo, $SubjectArg, $BodyArg
        $records = @()
        if (Test-Path $outbox) {
            $records = @(Get-Content $outbox | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        }
        Remove-Item $outbox -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            ExitCode = $result.ExitCode
            Output   = $result.Output
            Records  = $records
        }
    }
}

Describe 'Send-SelfAlert.ps1 (mock mode)' {
    It 'sends exactly one text-only email with the given from, to, subject and body' {
        $res = Invoke-SelfAlert
        $res.ExitCode | Should -Be 0
        $res.Records.Count | Should -Be 1
        $res.Records[0].from | Should -Be 'reports@example.net'
        $res.Records[0].to | Should -Be 'adam@example.net'
        $res.Records[0].subject | Should -Be 'Disk space low'
        $res.Records[0].body | Should -Be 'The nightly job reported low disk space.'
        $res.Records[0].html | Should -BeNullOrEmpty
    }

    It 'prints only a status line: no address, subject or body' {
        $res = Invoke-SelfAlert
        $res.Output | Should -Match 'self-alert sent'
        $res.Output | Should -Not -Match '@example\.'
        $res.Output | Should -Not -Match 'Disk space low'
        $res.Output | Should -Not -Match 'nightly job'
    }

    It 'fails and sends nothing when <Missing> is not set' -ForEach @(
        @{ Missing = 'SELF_ALERT_FROM'; AlertFrom = ''; AlertTo = 'adam@example.net' }
        @{ Missing = 'SELF_ALERT_TO'; AlertFrom = 'reports@example.net'; AlertTo = '' }
    ) {
        $res = Invoke-SelfAlert -AlertFrom $AlertFrom -AlertTo $AlertTo
        $res.ExitCode | Should -Not -Be 0
        $res.Output | Should -Match 'SELF_ALERT_FROM and SELF_ALERT_TO must be set'
        $res.Records.Count | Should -Be 0
    }

    It 'fails and sends nothing for a whitespace-only <Field>' -ForEach @(
        @{ Field = 'subject'; SubjectArg = " `t "; BodyArg = 'Some body.' }
        @{ Field = 'body'; SubjectArg = 'Some subject'; BodyArg = "  `r`n  " }
    ) {
        $res = Invoke-SelfAlert -SubjectArg $SubjectArg -BodyArg $BodyArg
        $res.ExitCode | Should -Not -Be 0
        $res.Records.Count | Should -Be 0
    }

    It 'collapses CR, LF and tab runs in the subject to single spaces and trims the body' {
        $res = Invoke-SelfAlert -SubjectArg "  Line one`r`nline two`t`tline three`n" -BodyArg "`n  Body text.  `n"
        $res.ExitCode | Should -Be 0
        $res.Records.Count | Should -Be 1
        $res.Records[0].subject | Should -Be 'Line one line two line three'
        $res.Records[0].body | Should -Be 'Body text.'
    }

    It 'truncates an over-long subject to 200 characters and body to 4000' {
        $res = Invoke-SelfAlert -SubjectArg ('s' * 250) -BodyArg ('b' * 4500)
        $res.ExitCode | Should -Be 0
        $res.Records.Count | Should -Be 1
        $res.Records[0].subject | Should -Be ('s' * 200)
        $res.Records[0].body | Should -Be ('b' * 4000)
    }

    It 'keeps a subject and body that are exactly at the caps' {
        $res = Invoke-SelfAlert -SubjectArg ('s' * 200) -BodyArg ('b' * 4000)
        $res.Records[0].subject.Length | Should -Be 200
        $res.Records[0].body.Length | Should -Be 4000
    }

    It 'fails and sends nothing when From is not a sending identity' {
        $res = Invoke-SelfAlert -AlertFrom 'stranger@example.com'
        $res.ExitCode | Should -Not -Be 0
        $res.Records.Count | Should -Be 0
    }
}
