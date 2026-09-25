#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Unit tests for .github/scripts/workflow-overlap.sh -- the check that names
  the fastmail-actions#20/#21 shape (issue #24): a Dependabot PR behind its
  base whose base has, since they diverged, changed a .github/workflows/*
  file the PR also changes. Each test builds a throwaway git repo under
  $TestDrive so the tests need no network and are order-independent.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath = Join-Path $script:Root '.github/scripts/workflow-overlap.sh'

    function New-TestRepo {
        $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $repo | Out-Null
        git -C $repo -c init.defaultBranch=main init -q
        git -C $repo config user.name test
        git -C $repo config user.email test@example.com
        git -C $repo config commit.gpgsign false
        return $repo
    }

    function Add-RepoCommit {
        param(
            [Parameter(Mandatory)][string]$Repo,
            [Parameter(Mandatory)][string]$RelPath,
            [Parameter(Mandatory)][string]$Content,
            [Parameter(Mandatory)][string]$Message
        )
        $full = Join-Path $Repo $RelPath
        $dir = Split-Path -Parent $full
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $full -Value $Content -NoNewline
        git -C $Repo add -A
        git -C $Repo commit -q -m $Message | Out-Null
    }

    function Invoke-WorkflowOverlap {
        param(
            [Parameter(Mandatory)][string]$Repo,
            [Parameter(Mandatory)][string]$BaseRef,
            [Parameter(Mandatory)][string]$HeadRef
        )
        Push-Location $Repo
        try {
            $out = & bash $script:ScriptPath $BaseRef $HeadRef 2>$null
            $code = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        return [pscustomobject]@{
            Lines    = @($out)
            ExitCode = $code
        }
    }
}

Describe 'workflow-overlap.sh' {
    It 'reports the shared workflow file when base and head each edited it after diverging (the #20/#21 shape)' {
        $repo = New-TestRepo
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/tests.yml' -Content "line1`nline2`nline3`n" -Message 'initial'
        git -C $repo branch base
        git -C $repo branch head
        git -C $repo checkout -q base
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/tests.yml' -Content "line1-base`nline2`nline3`n" -Message 'base edit'
        git -C $repo checkout -q head
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/tests.yml' -Content "line1`nline2`nline3-head`n" -Message 'head edit'

        $result = Invoke-WorkflowOverlap -Repo $repo -BaseRef 'base' -HeadRef 'head'
        @($result.Lines) | Should -Be @('.github/workflows/tests.yml')
        $result.ExitCode | Should -Be 0
    }

    It 'reports nothing once head is rebased onto base so it contains base' {
        $repo = New-TestRepo
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/tests.yml' -Content "line1`nline2`nline3`n" -Message 'initial'
        git -C $repo branch base
        git -C $repo checkout -q base
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/tests.yml' -Content "line1-base`nline2`nline3`n" -Message 'base edit'
        git -C $repo checkout -q -b head base
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/tests.yml' -Content "line1-base`nline2`nline3-head`n" -Message 'head edit on top of base'

        $result = Invoke-WorkflowOverlap -Repo $repo -BaseRef 'base' -HeadRef 'head'
        $result.Lines.Count | Should -Be 0
        $result.ExitCode | Should -Be 0
    }

    It 'reports nothing when base and head changed different workflow files' {
        $repo = New-TestRepo
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/a.yml' -Content "a1`n" -Message 'initial a'
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/b.yml' -Content "b1`n" -Message 'initial b'
        git -C $repo branch base
        git -C $repo branch head
        git -C $repo checkout -q base
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/a.yml' -Content "a2`n" -Message 'base edits a'
        git -C $repo checkout -q head
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/b.yml' -Content "b2`n" -Message 'head edits b'

        $result = Invoke-WorkflowOverlap -Repo $repo -BaseRef 'base' -HeadRef 'head'
        $result.Lines.Count | Should -Be 0
        $result.ExitCode | Should -Be 0
    }

    It 'reports nothing when base only changed a non-workflow file' {
        $repo = New-TestRepo
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/tests.yml' -Content "line1`n" -Message 'initial workflow'
        Add-RepoCommit -Repo $repo -RelPath 'README.md' -Content "readme`n" -Message 'initial readme'
        git -C $repo branch base
        git -C $repo branch head
        git -C $repo checkout -q base
        Add-RepoCommit -Repo $repo -RelPath 'README.md' -Content "readme-updated`n" -Message 'base edits README'
        git -C $repo checkout -q head
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/tests.yml' -Content "line1-head`n" -Message 'head edits workflow'

        $result = Invoke-WorkflowOverlap -Repo $repo -BaseRef 'base' -HeadRef 'head'
        $result.Lines.Count | Should -Be 0
        $result.ExitCode | Should -Be 0
    }

    It 'exits 2 with no stdout for a ref that does not exist' {
        $repo = New-TestRepo
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/tests.yml' -Content "line1`n" -Message 'initial'

        $result = Invoke-WorkflowOverlap -Repo $repo -BaseRef 'does-not-exist' -HeadRef 'main'
        $result.ExitCode | Should -Be 2
        $result.Lines.Count | Should -Be 0
    }
}

Describe 'dependabot-auto-merge.yml sweep invokes workflow-overlap.sh' {
    It 'shells out to the real workflow-overlap.sh with a properly quoted base ref, and sees the #20/#21 overlap' {
        # Extract job.sweep's "Sweep open Dependabot PRs" step's `run:` text
        # with a real YAML parser (PyYAML), never a regex/line scan for
        # structure -- a line scan can't see whether the missing space before
        # `"origin/${base}"` (issue #24) makes bash try to run a nonexistent
        # file. If the job or step gets renamed, this python program exits
        # non-zero and the assertion below fails loudly instead of the test
        # silently matching nothing.
        $workflowPath = Join-Path $script:Root '.github/workflows/dependabot-auto-merge.yml'
        $pyExtract = Join-Path $TestDrive 'extract_sweep_run.py'
        Set-Content -Path $pyExtract -NoNewline -Value @'
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    doc = yaml.safe_load(f)

steps = ((doc.get("jobs") or {}).get("sweep") or {}).get("steps") or []
for step in steps:
    if isinstance(step, dict) and step.get("name") == "Sweep open Dependabot PRs":
        run = step.get("run")
        if not isinstance(run, str):
            sys.exit(1)
        sys.stdout.write(run)
        sys.exit(0)

sys.exit(1)
'@

        $runText = & python3 $pyExtract $workflowPath
        $LASTEXITCODE | Should -Be 0

        # A lexical token match is fine here -- we're not parsing structure,
        # just picking the one line out of the already-extracted run script.
        $runLines = $runText -split "`n"
        $overlapLines = @($runLines | Where-Object {
            $_ -like '*workflow-overlap.sh*' -and ($_.TrimStart() -like 'if overlap=*')
        })
        $overlapLines.Count | Should -Be 1
        $extractedLine = $overlapLines[0].TrimStart()

        # Fixture repo, the #20/#21 shape: base and head both edit
        # tests.yml after diverging from their common ancestor.
        $repo = New-TestRepo
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/tests.yml' -Content "line1`nline2`nline3`n" -Message 'initial'
        git -C $repo branch base
        git -C $repo branch head
        git -C $repo checkout -q base
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/tests.yml' -Content "line1-base`nline2`nline3`n" -Message 'base edit'
        $baseTip = (git -C $repo rev-parse base).Trim()
        git -C $repo checkout -q head
        Add-RepoCommit -Repo $repo -RelPath '.github/workflows/tests.yml' -Content "line1`nline2`nline3-head`n" -Message 'head edit'
        $headTip = (git -C $repo rev-parse head).Trim()

        # The real script, dropped untracked into the fixture's working
        # tree -- it just needs to exist on disk at the path the sweep runs.
        $fixtureScriptDir = Join-Path $repo '.github/scripts'
        New-Item -ItemType Directory -Path $fixtureScriptDir -Force | Out-Null
        Copy-Item -Path $script:ScriptPath -Destination (Join-Path $fixtureScriptDir 'workflow-overlap.sh')

        # The exact refs the sweep fetches into before invoking the script.
        git -C $repo update-ref refs/remotes/origin/main $baseTip
        git -C $repo update-ref refs/remotes/dependabot-sweep/pr-20 $headTip

        $harness = Join-Path $TestDrive 'sweep-harness.sh'
        $harnessContent = @"
set -euo pipefail
base=main
num=20
$extractedLine
  printf 'OVERLAP:%s\n' "`$overlap"
else
  echo 'NO-OVERLAP'
fi
"@
        Set-Content -Path $harness -NoNewline -Value $harnessContent

        Push-Location $repo
        try {
            $output = & bash $harness
            $code = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $code | Should -Be 0
        @($output) | Should -Be @('OVERLAP:.github/workflows/tests.yml')
    }
}
