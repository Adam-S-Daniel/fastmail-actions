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
