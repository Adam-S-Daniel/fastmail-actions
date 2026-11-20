#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Owner-guard tests for this repo's own workflows. A GitHub App holds
  "Actions: write" on this repository so other repositories can dispatch
  send-self-alert.yml, and that permission can start or re-run any workflow
  here, on any branch. Two fences, both locked here:

  1. Every job that reads a repository secret names the `mail` environment.
     The Fastmail token lives only there, and only the default branch may use
     that environment, so an older copy of a workflow on another branch gets
     no token. (The environment's branch rule and the absence of a
     repository-level token are repository SETTINGS; the README says how to
     check them. This test covers what a commit can show.)
  2. Every such job begins with the owner guard, except the ones listed in
     $OpenToDispatchers. A new job that reads a secret is fenced by default:
     this test fails until it carries the guard or is listed as open on
     purpose.

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

    # Any way an expression can read a secret other than the built-in token:
    # secrets.NAME, secrets['NAME'], the whole context (toJSON(secrets)), or a
    # reusable-workflow job's `secrets: inherit`.
    function Test-ReadsSecret([string]$Json) {
        $named = [regex]::Matches($Json, 'secrets\.([A-Za-z0-9_]+)') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -cne 'GITHUB_TOKEN' }
        if ($named) { return $true }
        # Any other mention of the context inside an expression, or the
        # `secrets: inherit` key (serialized as "secrets": "inherit").
        return [bool]([regex]::IsMatch($Json, '\$\{\{[^}]*\bsecrets\s*[\[)\s}]') -or
            [regex]::IsMatch($Json, '"secrets"\s*:\s*"inherit"'))
    }

    $script:SecretJobs = @()
    $script:OutsideJobs = @()
    $script:JobCount = 0
    if (-not $script:YamlMissing) {
        $root = Split-Path -Parent $PSScriptRoot
        foreach ($f in Get-ChildItem (Join-Path $root '.github/workflows') -File |
                Where-Object { $_.Extension -cin '.yml', '.yaml' }) {
            $wf = ConvertFrom-Yaml (Get-Content -Raw $f.FullName)
            # Everything that is not a job (workflow-level env, defaults,
            # run-name, concurrency): a secret read there reaches every job.
            $rest = @{}
            foreach ($k in $wf.Keys) { if ($k -cne 'jobs') { $rest[$k] = $wf[$k] } }
            if (Test-ReadsSecret ($rest | ConvertTo-Json -Depth 20)) { $script:OutsideJobs += $f.Name }
            foreach ($id in $wf['jobs'].Keys) {
                $script:JobCount++
                $job = $wf['jobs'][$id]
                if (-not (Test-ReadsSecret ($job | ConvertTo-Json -Depth 20))) { continue }
                $script:SecretJobs += @{
                    Key   = "$($f.Name)/$id"
                    Open  = $script:OpenToDispatchers -ccontains "$($f.Name)/$id"
                    Job   = $job
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
    It 'discovered exactly the three mail jobs among <Jobs> jobs' -ForEach @(@{
            Keys = @($script:SecretJobs | ForEach-Object { $_.Key } | Sort-Object)
            Jobs = $script:JobCount
        }) {
        $Jobs | Should -BeGreaterThan 3
        $Keys | Should -Be @(
            'add-from-address.yml/add-from-address'
            'add-received-from-addresses.yml/add-received-from-addresses'
            'send-self-alert.yml/send-self-alert'
        )
    }

    It 'no secret is read outside a job (workflow-level env would reach every job)' -ForEach @(@{
            Files = @($script:OutsideJobs)
        }) {
        $Files | Should -BeNullOrEmpty
    }

    It 'exactly one job is left open to dispatchers, and it exists' -ForEach @(@{
            Open = @($script:SecretJobs | Where-Object { $_.Open } | ForEach-Object { $_.Key })
        }) {
        $Open | Should -Be @('send-self-alert.yml/send-self-alert')
    }

    It '<Key> takes its secrets from the mail environment and nothing reads one before its steps' -ForEach $script:SecretJobs {
        $Job['environment'] | Should -BeExactly 'mail'
        # A container or service definition is resolved before the first step.
        $Job.ContainsKey('container') | Should -BeFalse
        $Job.ContainsKey('services') | Should -BeFalse
        # A reusable-workflow job has no steps to guard.
        $Job.ContainsKey('uses') | Should -BeFalse
    }

    It '<Key> begins with the owner guard' -ForEach ($script:SecretJobs | Where-Object { -not $_.Open }) {
        $First['name'] | Should -BeExactly 'Refuse anyone but the repository owner'
        # The whole condition, exactly. A re-run keeps the original actor,
        # event and inputs, so a manual run needs the owner as BOTH the
        # original actor and this attempt's actor; a scheduled run passes on
        # its first attempt or when the owner re-runs it; act is exempt.
        $First['if'] | Should -BeExactly "`${{ env.ACT != 'true' && !((github.event_name == 'schedule' && (github.run_attempt == 1 || github.triggering_actor == github.repository_owner)) || (github.event_name != 'schedule' && github.actor == github.repository_owner && github.triggering_actor == github.repository_owner)) }}"
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
