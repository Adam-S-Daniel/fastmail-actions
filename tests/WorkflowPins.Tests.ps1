#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Action-pin tests for this repo's own workflows: every third-party step
  `uses:` must be locked in .github/workflows/actions.lock, every non-local
  reusable workflow must carry a full commit SHA, and the `pester` job's
  "Verify action lockfile" step must keep its guard lines. Workflow and
  lockfile YAML is parsed with powershell-yaml. CI installs it; locally the
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
    # Hashtable keys from ConvertFrom-Yaml may compare case-insensitively; a
    # lockfile key must match the workflow's uses: byte for byte, so look keys
    # up with -ceq and refuse an ambiguous match.
    function Get-CaseSensitiveValue($Map, [string]$Key) {
        $hits = @($Map.Keys | Where-Object { $_ -ceq $Key })
        if ($hits.Count -gt 1) { throw "ambiguous key: $Key" }
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
        $dep = Get-CaseSensitiveValue $script:Lock['dependencies'] $Uses
        $dep | Should -Not -BeNullOrEmpty
        $dep['commit'] | Should -MatchExactly '^sha1-[0-9a-f]{40}$'
        $dep['ref'] | Should -BeExactly $Uses.Substring($Uses.LastIndexOf('@') + 1)
        $listed = @(Get-CaseSensitiveValue $script:Lock['workflows'] ".github/workflows/$File")
        ($listed -ccontains $Uses) | Should -BeTrue -Because "actions.lock workflows entry for $File must list $Uses"
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

    It 'takes GH_TOKEN from github.token' {
        $script:VerifyStep['env']['GH_TOKEN'] | Should -BeExactly '${{ github.token }}'
    }

    It 'exits 1 on failure' {
        (($script:VerifyStep['run'] -split "`n" | ForEach-Object { $_.Trim() }) -ccontains 'exit 1') | Should -BeTrue
    }

    It 'keeps the guard line: <Line>' -ForEach @(
        @{ Line = 'set -euo pipefail' }
        @{ Line = 'gh release download v0.2.0 -R github/gh-actions-lock -p linux-amd64 -O "$ext/gh-actions-lock"' }
        @{ Line = 'echo "79ec84c191667fd935a277e6fd3662cf5d3669cccc9e99998731d8f306f373b6  $ext/gh-actions-lock" | sha256sum -c -' }
        @{ Line = '(cd "$ext" && gh extension install .)' }
        @{ Line = 'out=$(gh actions-lock --verify --no-interactive --json=valid,findings) || rc=$?' }
        @{ Line = 'if [[ "$rc" -ne 0 ]] || ! jq -e ''.valid == true and ([.findings[] | select(.category != "cooldown-config-ignored")] | length) == 0'' <<<"$out" >/dev/null; then' }
    ) {
        (($script:VerifyStep['run'] -split "`n") -ccontains $Line) | Should -BeTrue -Because "the verify step must keep: $Line"
    }
}

Describe 'Dependabot auto-merge allows the action lockfile' -Skip:$script:YamlMissing {
    # Dependabot rewrites .github/workflows/actions.lock with every action bump,
    # so both copies of the manifest-path allowlist must accept exactly it.
    # Each copy's `case "$f" in ... esac` block is lifted out of the parsed
    # step and run by bash against candidate paths.
    BeforeAll {
        $wf = ConvertFrom-Yaml (Get-Content -Raw (Join-Path $script:WorkflowDir 'dependabot-auto-merge.yml'))
        $script:AllowlistRuns = @{
            'auto-merge' = (@($wf['jobs']['auto-merge']['steps']) | Where-Object { $_['id'] -ceq 'paths' })['run']
            'sweep'      = (@($wf['jobs']['sweep']['steps']) | Where-Object { $_['name'] -ceq 'Sweep open Dependabot PRs' })['run']
        }

        function Test-Allowlisted([string]$Job, [string]$Path) {
            $lines = $script:AllowlistRuns[$Job] -split "`n"
            $start = [array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l.Trim() -ceq 'case "$f" in' })
            if ($start -lt 0) { throw "no case block in $Job" }
            $end = [array]::FindIndex([string[]]$lines, $start, [Predicate[string]] { param($l) $l.Trim() -ceq 'esac' })
            if ($end -lt 0) { throw "no esac in $Job" }
            $block = ($lines[$start..$end] -join "`n")
            $script = "REJECT=0`nnum=1`nf=`"`$1`"`n$block`necho `"REJECT=`$REJECT`""
            $out = & bash -c $script bash $Path 2>$null
            if ($LASTEXITCODE -ne 0) { throw "bash exited $LASTEXITCODE" }
            return (@($out)[-1] -ceq 'REJECT=0')
        }
    }

    It '<Job> accepts .github/workflows/actions.lock' -ForEach @(@{ Job = 'auto-merge' }, @{ Job = 'sweep' }) {
        Test-Allowlisted $Job '.github/workflows/actions.lock' | Should -BeTrue
    }

    It '<Job> still rejects <Path>' -ForEach @(
        @{ Job = 'auto-merge'; Path = '.github/workflows/actions.lock.bak' }
        @{ Job = 'auto-merge'; Path = 'README.md' }
        @{ Job = 'sweep'; Path = '.github/workflows/actions.lock.bak' }
        @{ Job = 'sweep'; Path = 'README.md' }
    ) {
        Test-Allowlisted $Job $Path | Should -BeFalse
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
