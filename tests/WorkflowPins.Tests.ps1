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
                Where-Object { $_.Extension -in '.yml', '.yaml' }) {
            $wf = ConvertFrom-Yaml (Get-Content -Raw $f.FullName)
            foreach ($job in $wf['jobs'].Values) {
                foreach ($step in @($job['steps']) | Where-Object { $_ }) {
                    $u = $step['uses']
                    if (-not $u) { continue }
                    if ($u -like './*' -or $u -like '$/*' -or $u -like 'docker://*' -or
                        $u -like 'Adam-S-Daniel/cms-platform/*') { continue }
                    $script:LockCases += @{ File = $f.Name; Uses = $u }
                }
            }
        }
    }
}

BeforeAll {
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

    It '<Uses> in <File> is locked to a commit' -ForEach $script:LockCases {
        $dep = $script:Lock['dependencies'][$Uses]
        $dep | Should -Not -BeNullOrEmpty
        $dep['commit'] | Should -MatchExactly '^sha1-[0-9a-f]{40}$'
        $dep['ref'] | Should -BeExactly $Uses.Substring($Uses.LastIndexOf('@') + 1)
        @($script:Lock['workflows'][".github/workflows/$File"]) | Should -Contain $Uses
    }
}

Describe 'reusable workflows are pinned to a full commit SHA' -Skip:$script:YamlMissing {
    It 'every non-local jobs.<id>.uses ends in @ plus 40 lowercase hex' {
        # actions.lock does not lock reusable workflows, and neither --verify nor sha_pinning_required flags a tag there.
        $bad = @()
        foreach ($f in Get-ChildItem $script:WorkflowDir -File | Where-Object { $_.Extension -in '.yml', '.yaml' }) {
            $wf = ConvertFrom-Yaml (Get-Content -Raw $f.FullName)
            foreach ($id in $wf['jobs'].Keys) {
                $u = $wf['jobs'][$id]['uses']
                if (-not $u -or $u -like './*' -or $u -like '$/*' -or $u -like 'Adam-S-Daniel/cms-platform/*') { continue }
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

    It 'keeps the guard line: <Line>' -ForEach @(
        @{ Line = 'set -euo pipefail' }
        @{ Line = 'gh release download v0.2.0 -R github/gh-actions-lock -p linux-amd64 -O "$ext/gh-actions-lock"' }
        @{ Line = 'echo "79ec84c191667fd935a277e6fd3662cf5d3669cccc9e99998731d8f306f373b6  $ext/gh-actions-lock" | sha256sum -c -' }
        @{ Line = '(cd "$ext" && gh extension install .)' }
        @{ Line = 'out=$(gh actions-lock --verify --no-interactive --json=valid,findings) || rc=$?' }
        @{ Line = 'if [[ "$rc" -ne 0 ]] || ! jq -e ''.valid == true and ([.findings[] | select(.category != "cooldown-config-ignored")] | length) == 0'' <<<"$out" >/dev/null; then' }
    ) {
        ($script:VerifyStep['run'] -split "`n") | Should -Contain $Line
    }
}
