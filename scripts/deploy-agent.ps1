#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Wrapper around src/deploy_agent.py.

.DESCRIPTION
    Creates/uses a local .venv and installs requirements.txt on first run,
    then forwards all arguments to the Python script.

.EXAMPLE
    ./scripts/deploy-agent.ps1 configs/dev-test-connections-agent-gpt4.yaml

.EXAMPLE
    ./scripts/deploy-agent.ps1 configs/dev-test-connections-agent-gpt4.yaml --invoke "Are you ready?"

.EXAMPLE
    ./scripts/deploy-agent.ps1 configs/dev-test-connections-agent-gpt4.yaml --delete

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
$Entrypoint   = Join-Path $RepoRoot 'src/deploy_agent.py'

if ($Args.Count -eq 0) {
    Write-Error 'Usage: deploy-agent.ps1 <config.yaml> [--invoke [MESSAGE]] [--delete]'
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

& $Py $Entrypoint @Args
exit $LASTEXITCODE
