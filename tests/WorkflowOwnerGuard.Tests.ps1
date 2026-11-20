#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Owner-guard tests for this repo's own workflows. A GitHub App holds
  "Actions: write" on this repository so other repositories can dispatch
  send-self-alert.yml, and that permission can start or re-run any workflow
  here. Every job that reads a repository secret must therefore begin with the
  owner guard, except the ones listed in $OpenToDispatchers. A new workflow
  that reads a secret is fenced by default: this test fails until it either
  carries the guard or is added to that list on purpose.

  Workflow YAML is parsed with powershell-yaml. CI installs it; locally the
  tests skip when it is missing.
#>

BeforeDiscovery {
    $script:YamlMissing = -not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)
    if ($script:YamlMissing -and (Get-Module -ListAvailable powershell-yaml)) {
        Import-Module powershell-yaml
        $script:YamlMissing = $false
    }
    if ($script:YamlMissing -and $env:CI) {
        throw 'powershell-yaml is required in CI (Install-Module powershell-yaml)'
    }

    # Jobs another repository's App is MEANT to start. It sends a short fixed
    # alert to the owner and changes nothing in the mail account.
    $script:OpenToDispatchers = @('send-self-alert.yml/send-self-alert')

    $script:SecretJobs = @()
    if (-not $script:YamlMissing) {
        $root = Split-Path -Parent $PSScriptRoot
        foreach ($f in Get-ChildItem (Join-Path $root '.github/workflows') -File |
                Where-Object { $_.Extension -cin '.yml', '.yaml' }) {
            $wf = ConvertFrom-Yaml (Get-Content -Raw $f.FullName)
            foreach ($id in $wf['jobs'].Keys) {
                $job = $wf['jobs'][$id]
                # Anything in the job that names a repository secret other than
                # the built-in token: a step's env or with, or the job's own.
                $text = $job | ConvertTo-Json -Depth 20
                $reads = [regex]::Matches($text, 'secrets\.([A-Za-z0-9_]+)') |
                    ForEach-Object { $_.Groups[1].Value } |
                    Where-Object { $_ -cne 'GITHUB_TOKEN' }
                if (-not $reads) { continue }
                $script:SecretJobs += @{
                    Key   = "$($f.Name)/$id"
                    Open  = $script:OpenToDispatchers -ccontains "$($f.Name)/$id"
                    First = @($job['steps'])[0]
                }
            }
        }
    }
}

Describe 'jobs that read a repository secret' -Skip:$script:YamlMissing {
    # -ForEach over an empty list generates no tests and passes silently, so
    # prove discovery found the three jobs it should. (Discovery-time values
    # reach a test only through -ForEach.)
    It 'discovered the mail jobs' -ForEach @(@{ Keys = @($script:SecretJobs | ForEach-Object { $_.Key }) }) {
        $Keys | Should -Contain 'add-from-address.yml/add-from-address'
        $Keys | Should -Contain 'add-received-from-addresses.yml/add-received-from-addresses'
        $Keys | Should -Contain 'send-self-alert.yml/send-self-alert'
    }

    It 'exactly one job is left open to dispatchers, and it exists' -ForEach @(@{
            Open = @($script:SecretJobs | Where-Object { $_.Open } | ForEach-Object { $_.Key })
        }) {
        $Open | Should -Be @('send-self-alert.yml/send-self-alert')
    }

    It '<Key> begins with the owner guard' -ForEach ($script:SecretJobs | Where-Object { -not $_.Open }) {
        $First['name'] | Should -BeExactly 'Refuse anyone but the repository owner'
        # The whole condition, exactly. A re-run keeps the original actor and
        # event, so it tests the attempt's own actor, and lets the schedule
        # through on its first attempt only; act is exempt.
        $First['if'] | Should -BeExactly "`${{ env.ACT != 'true' && github.triggering_actor != github.repository_owner && !(github.event_name == 'schedule' && github.run_attempt == 1) }}"
        $First.ContainsKey('continue-on-error') | Should -BeFalse
        $First.ContainsKey('uses') | Should -BeFalse
        $First.ContainsKey('env') | Should -BeFalse
        @($First['run'] -split "`n" | Where-Object { $_ })[-1].Trim() | Should -BeExactly 'exit 1'
    }

    It '<Key> is open on purpose and carries no guard' -ForEach ($script:SecretJobs | Where-Object { $_.Open }) {
        $First['name'] | Should -Not -BeExactly 'Refuse anyone but the repository owner'
    }
}

Describe 'the guard step refuses when it runs' -Skip:$script:YamlMissing {
    It 'the guard script in <Key> exits 1 and prints one error line' -ForEach ($script:SecretJobs | Where-Object { -not $_.Open }) {
        $out = $First['run'] | bash 2>&1
        $LASTEXITCODE | Should -Be 1
        @($out) | Should -Be @('::error::Only the repository owner may run this workflow.')
    }
}
