#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Action-pin tests for this repo's own workflows: every third-party step
  `uses:` must be locked in .github/workflows/actions.lock, every non-local
  reusable workflow must carry a full commit SHA, and the `pester` job's
  "Verify action lockfile" step must be the shared verify-actions-lock
  action. Workflow and lockfile YAML is parsed with powershell-yaml. CI
  installs it; locally the tests skip when it is missing.
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

    $script:LockCases = @()
    if (-not $script:YamlMissing) {
        $root = Split-Path -Parent $PSScriptRoot
        foreach ($f in Get-ChildItem (Join-Path $root '.github/workflows') -File |
                Where-Object { $_.Extension -cin '.yml', '.yaml' }) {
            $wf = ConvertFrom-Yaml (Get-Content -Raw $f.FullName)
            foreach ($job in $wf['jobs'].Values) {
                foreach ($step in @($job['steps']) | Where-Object { $_ }) {
                    $u = $step['uses']
                    if (-not $u) { continue }
                    if ($u -clike './*' -or $u -clike '$/*' -or $u -clike 'docker://*' -or
                        $u -clike 'Adam-S-Daniel/cms-platform/*') { continue }
                    $script:LockCases += @{ File = $f.Name; Uses = $u }
                }
            }
        }
    }
}

BeforeAll {
    # gh-actions-lock lowercases the owner/repo part of a lockfile key, so match
    # that part (before the last @) case-insensitively and the ref (after the
    # last @) exactly; refuse an ambiguous match. Hashtable keys from
    # ConvertFrom-Yaml may compare case-insensitively, so enumerate them.
    function Get-CaseSensitiveValue($Map, [string]$Key) {
        $hits = @($Map.Keys | Where-Object { $_ -ceq $Key })
        if ($hits.Count -gt 1) { throw "ambiguous key: $Key" }
        if ($hits.Count -eq 0) { return $null }
        return $Map[$hits[0]]
    }

    function Get-LockValue($Map, [string]$Uses) {
        $at = $Uses.LastIndexOf('@')
        $name = $Uses.Substring(0, $at)
        $ref = $Uses.Substring($at + 1)
        $hits = @($Map.Keys | Where-Object {
                $i = ([string]$_).LastIndexOf('@')
                $i -ge 0 -and ([string]$_).Substring(0, $i) -ieq $name -and ([string]$_).Substring($i + 1) -ceq $ref
            })
        if ($hits.Count -gt 1) { throw "ambiguous key: $Uses" }
        if ($hits.Count -eq 0) { return $null }
        return $Map[$hits[0]]
    }

    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:WorkflowDir = Join-Path $script:Root '.github/workflows'
    if (-not $script:YamlMissing) {
        if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) { Import-Module powershell-yaml }
        $script:Lock = ConvertFrom-Yaml (Get-Content -Raw (Join-Path $script:WorkflowDir 'actions.lock'))
    }
}

Describe 'actions.lock covers every third-party step uses' -Skip:$script:YamlMissing {
    It 'has a non-empty lockfile' {
        $script:Lock['dependencies'].Count | Should -BeGreaterThan 0
    }

    # -ForEach over an empty list generates no tests and passes silently, so
    # prove discovery found something to check.
    It 'discovered third-party step uses to check (<Count>)' -ForEach @(@{ Count = @($script:LockCases).Count }) {
        $Count | Should -BeGreaterThan 0
    }

    It '<Uses> in <File> is locked to a commit' -ForEach $script:LockCases {
        $dep = Get-LockValue $script:Lock['dependencies'] $Uses
        $dep | Should -Not -BeNullOrEmpty
        $dep['commit'] | Should -MatchExactly '^sha1-[0-9a-f]{40}$'
        $dep['ref'] | Should -BeExactly $Uses.Substring($Uses.LastIndexOf('@') + 1)
        $listed = @(Get-CaseSensitiveValue $script:Lock['workflows'] ".github/workflows/$File")
        $ref = $Uses.Substring($Uses.LastIndexOf('@') + 1)
        $hit = @($listed | Where-Object { $i = ([string]$_).LastIndexOf('@'); $i -ge 0 -and ([string]$_).Substring(0, $i) -ieq $Uses.Substring(0, $Uses.LastIndexOf('@')) -and ([string]$_).Substring($i + 1) -ceq $ref })
        $hit.Count | Should -Be 1 -Because "actions.lock workflows entry for $File must list $Uses"
    }
}

Describe 'reusable workflows are pinned to a full commit SHA' -Skip:$script:YamlMissing {
    It 'every non-local jobs.<id>.uses ends in @ plus 40 lowercase hex' {
        # actions.lock does not lock reusable workflows, and neither --verify nor sha_pinning_required flags a tag there.
        $bad = @()
        foreach ($f in Get-ChildItem $script:WorkflowDir -File | Where-Object { $_.Extension -cin '.yml', '.yaml' }) {
            $wf = ConvertFrom-Yaml (Get-Content -Raw $f.FullName)
            foreach ($id in $wf['jobs'].Keys) {
                $u = $wf['jobs'][$id]['uses']
                if (-not $u -or $u -clike './*' -or $u -clike '$/*' -or $u -clike 'Adam-S-Daniel/cms-platform/*') { continue }
                if ($u -cnotmatch '@[0-9a-f]{40}$') { $bad += "$($f.Name) jobs.$id.uses: $u" }
            }
        }
        $bad | Should -BeNullOrEmpty
    }
}

Describe 'Verify action lockfile step' -Skip:$script:YamlMissing {
    BeforeAll {
        $wf = ConvertFrom-Yaml (Get-Content -Raw (Join-Path $script:WorkflowDir 'tests.yml'))
        $script:VerifyStep = @($wf['jobs']['pester']['steps']) | Where-Object { $_['name'] -ceq 'Verify action lockfile' }
    }

    It 'exists exactly once in the pester job' {
        @($script:VerifyStep).Count | Should -Be 1
    }

    It 'has no continue-on-error' {
        $script:VerifyStep.ContainsKey('continue-on-error') | Should -BeFalse
    }

    It 'uses the shared verify-actions-lock action at a release tag' {
        $script:VerifyStep['uses'] | Should -MatchExactly '^Adam-S-Daniel/verify-actions-lock@v\d+\.\d+\.\d+$'
    }

    It 'has no if, so the job runs it on every pull request' {
        $script:VerifyStep.ContainsKey('if') | Should -BeFalse
    }
}

Describe 'tests.yml salient step sees both sides of a rename' -Skip:$script:YamlMissing {
    It 'diffs with --no-renames' {
        $wf = ConvertFrom-Yaml (Get-Content -Raw (Join-Path $script:WorkflowDir 'tests.yml'))
        $runs = foreach ($job in $wf['jobs'].Values) {
            foreach ($step in @($job['steps']) | Where-Object { $_ }) {
                if ($step['run'] -and $step['run'].Contains('git diff')) { $step['run'] }
            }
        }
        $diffLines = @($runs -split "`n" | Where-Object { $_.Contains('git diff') })
        $diffLines.Count | Should -BeGreaterThan 0
        foreach ($line in $diffLines) {
            $line | Should -MatchExactly 'git diff --no-renames --name-only '
        }
    }
}
