#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Wrapper around src/deploy_code_agent.py.

.DESCRIPTION
    Deploys a CODE-BASED Foundry Hosted Agent: no Docker image and no ACR. The
    script zips the source folder (agent.sourceDir) and uploads it; Foundry builds
    and runs it for you and injects FOUNDRY_PROJECT_ENDPOINT automatically.

    Creates/uses a local .venv and installs requirements.txt on first run,
    then forwards all arguments to the Python script.

.EXAMPLE
    ./scripts/deploy-code-agent.ps1 configs/code-agent.yaml

.EXAMPLE
    ./scripts/deploy-code-agent.ps1 configs/code-agent.yaml --invoke "Are you ready?"

.EXAMPLE
    ./scripts/deploy-code-agent.ps1 configs/code-agent.yaml --delete

.NOTES
    Env vars:
      PYTHON     Python interpreter to bootstrap the venv (default: python)
      VENV_DIR   Virtualenv location (default: <repo>/.venv)
      SKIP_VENV  If set to "1", run with the current interpreter (no venv).
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir

$Python       = if ($env:PYTHON) { $env:PYTHON } else { 'python' }
$VenvDir      = if ($env:VENV_DIR) { $env:VENV_DIR } else { Join-Path $RepoRoot '.venv' }
$Requirements = Join-Path $RepoRoot 'requirements.txt'
$Entrypoint   = Join-Path $RepoRoot 'src/deploy_code_agent.py'

if ($Args.Count -eq 0) {
    $Config = 'configs/code-agent.yaml'
    $DeployArgs = @()
}
else {
    $Config = $Args[0]
    $DeployArgs = if ($Args.Count -gt 1) { $Args[1..($Args.Count - 1)] } else { @() }
}

$ConfigPath = $Config
if (-not (Test-Path $ConfigPath)) {
    $ConfigPath = Join-Path $RepoRoot $Config
}
if (-not (Test-Path $ConfigPath)) {
    Write-Error "config not found: $Config"
    exit 1
}

if ($env:SKIP_VENV -eq '1') {
    $Py = $Python
}
else {
    if (-not (Test-Path $VenvDir)) {
        Write-Host "-> Creating virtualenv: $VenvDir"
        & $Python -m venv $VenvDir
        $VenvPython = if ($IsWindows) { Join-Path $VenvDir 'Scripts/python.exe' } else { Join-Path $VenvDir 'bin/python' }
        & $VenvPython -m pip install --upgrade pip | Out-Null
        Write-Host '-> Installing requirements'
        & $VenvPython -m pip install -r $Requirements
    }
    $Py = if ($IsWindows) { Join-Path $VenvDir 'Scripts/python.exe' } else { Join-Path $VenvDir 'bin/python' }
}

& $Py $Entrypoint $ConfigPath @DeployArgs
exit $LASTEXITCODE
