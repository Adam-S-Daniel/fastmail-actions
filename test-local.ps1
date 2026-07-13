#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run the fastmail-actions test suite locally.

.DESCRIPTION
  By default runs the Pester suite in mock mode (fast, no Docker, no token).
  With -Act, runs the actual workflows through nektos/act in Docker, which
  exercises the real workflow YAML end-to-end against the mock JMAP fixture
  (act sets ACT=true, which flips the scripts into mock mode).

.EXAMPLE
  ./test-local.ps1                 # Pester, mock mode
  ./test-local.ps1 -Act            # run all three workflows via act
  ./test-local.ps1 -Act -Job add-from-address
#>
[CmdletBinding()]
param(
    [switch]$Act,
    [string]$Job
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

if (-not $Act) {
    Write-Host "Running Pester suite in mock mode..." -ForegroundColor Cyan
    $env:FASTMAIL_MOCK_DIR = Join-Path $root 'mocks'
    try {
        $cfg = New-PesterConfiguration
        $cfg.Run.Path = (Join-Path $root 'tests')
        $cfg.Run.Exit = $true
        $cfg.Output.Verbosity = 'Detailed'
        Invoke-Pester -Configuration $cfg
    } finally {
        Remove-Item Env:FASTMAIL_MOCK_DIR -ErrorAction SilentlyContinue
    }
    return
}

# --- act path ---
$actCmd = $null
foreach ($c in 'act', 'gh act') {
    $exe = ($c -split ' ')[0]
    if (Get-Command $exe -ErrorAction SilentlyContinue) { $actCmd = $c; break }
}
if (-not $actCmd) {
    throw "act not found. Install it (e.g. 'gh extension install nektos/gh-act', 'winget install nektos.act', or 'brew install act') and ensure Docker is running."
}

$workflows = @{
    'add-from-address'            = @('-W', '.github/workflows/add-from-address.yml', '--input', 'addresses=demo@example.net', '--input', 'whatif=true')
    'add-received-from-addresses' = @('-W', '.github/workflows/add-received-from-addresses.yml', '--input', 'whatif=true')
    'tests'                       = @('-W', '.github/workflows/tests.yml')
}

$targets = if ($Job) { @($Job) } else { $workflows.Keys }
Push-Location $root
try {
    foreach ($t in $targets) {
        if (-not $workflows.ContainsKey($t)) { throw "Unknown job '$t'. Known: $($workflows.Keys -join ', ')" }
        Write-Host "`n=== act: $t ===" -ForegroundColor Cyan
        $argList = @('workflow_dispatch') + $workflows[$t]
        & ($actCmd -split ' ')[0] @($actCmd -split ' ' | Select-Object -Skip 1) @argList
        if ($LASTEXITCODE -ne 0) { throw "act run for '$t' failed (exit $LASTEXITCODE)" }
    }
} finally {
    Pop-Location
}
