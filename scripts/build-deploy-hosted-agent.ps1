#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Build the hosted-agent container, push it to ACR, then create the Foundry
    hosted-agent version that runs it.

.DESCRIPTION
    Steps:
      1. Read agent.image from the config (registry / repo:tag).
      2. Ensure the Foundry PROJECT managed identity can pull from the ACR
         (grant AcrPull + enable the registry's ARM-audience AAD auth policy).
         This is the identity Foundry uses to pull the image; without it the
         version fails with [ImageError] Failed to pull container image.
      3. az acr build   -> builds the image in ACR and pushes it (linux/amd64).
      4. src/deploy_hosted_agent.py -> creates the agent version in Foundry.

.EXAMPLE
    ./scripts/build-deploy-hosted-agent.ps1

.EXAMPLE
    ./scripts/build-deploy-hosted-agent.ps1 configs/hosted-agent.yaml

.EXAMPLE
    ./scripts/build-deploy-hosted-agent.ps1 configs/hosted-agent.yaml --invoke "Hello"

.EXAMPLE
    $env:NEW_TAG = '1'; ./scripts/build-deploy-hosted-agent.ps1   # stamp a fresh timestamp tag

.NOTES
    Env vars:
      CONTEXT     Docker build context (default: <repo>/agents/hosted-agent)
      NEW_TAG     If set to "1", replace the image tag with a UTC timestamp and
                  rewrite the config before building/deploying.
      PYTHON      Python interpreter to bootstrap the venv (default: python)
      VENV_DIR    Virtualenv location (default: <repo>/.venv)
      SKIP_VENV   If set to "1", run deploy with the current interpreter (no venv).
      SKIP_BUILD  If set to "1", skip the ACR build and only deploy.
      SKIP_RBAC   If set to "1", skip ensuring ACR pull permissions for the
                  project identity (use when you don't have role-assignment rights).
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir

# --- Parse positional config + remaining deploy args -------------------------
if ($Args.Count -eq 0) {
    $Config = 'configs/hosted-agent.yaml'
    $DeployArgs = @()
}
else {
    $Config = $Args[0]
    $DeployArgs = if ($Args.Count -gt 1) { $Args[1..($Args.Count - 1)] } else { @() }
}
# Drop a leading "--" so callers can pass extra deploy args after it.
if ($DeployArgs.Count -gt 0 -and $DeployArgs[0] -eq '--') {
    $DeployArgs = if ($DeployArgs.Count -gt 1) { $DeployArgs[1..($DeployArgs.Count - 1)] } else { @() }
}

$ConfigPath = $Config
if (-not (Test-Path $ConfigPath)) {
    $ConfigPath = Join-Path $RepoRoot $Config
}
if (-not (Test-Path $ConfigPath)) {
    Write-Error "config not found: $Config"
    exit 1
}
$ConfigPath = (Resolve-Path $ConfigPath).Path

$Context      = if ($env:CONTEXT) { $env:CONTEXT } else { Join-Path $RepoRoot 'agents/hosted-agent' }
$Python       = if ($env:PYTHON) { $env:PYTHON } else { 'python' }
$VenvDir      = if ($env:VENV_DIR) { $env:VENV_DIR } else { Join-Path $RepoRoot '.venv' }
$Requirements = Join-Path $RepoRoot 'requirements.txt'
$Entrypoint   = Join-Path $RepoRoot 'src/deploy_hosted_agent.py'

# --- Read a scalar value from the config -------------------------------------
function Read-YamlScalar {
    param([Parameter(Mandatory)][string]$Key)
    foreach ($line in Get-Content -LiteralPath $ConfigPath) {
        if ($line -match "^\s*$([regex]::Escape($Key))\s*:\s*(.+?)\s*$") {
            # Strip an inline comment, surrounding quotes, and whitespace.
            $val = $Matches[1] -replace '\s*#.*$', ''
            $val = $val.Trim().Trim('"').Trim("'")
            if ($val) { return $val }
        }
    }
    return ''
}

$Image = Read-YamlScalar 'image'
if (-not $Image) {
    Write-Error "could not read 'agent.image' from $ConfigPath"
    exit 1
}

# --- Optionally stamp a fresh immutable tag ----------------------------------
if ($env:NEW_TAG -eq '1') {
    $Stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $ImageBase = $Image -replace ':[^:/]*$', ''
    $NewImage = "${ImageBase}:${Stamp}"
    Write-Host "-> Stamping new tag: $NewImage"
    # Replace the existing image line in the config (first occurrence only).
    $text = Get-Content -LiteralPath $ConfigPath -Raw
    $idx = $text.IndexOf($Image)
    if ($idx -ge 0) {
        $text = $text.Substring(0, $idx) + $NewImage + $text.Substring($idx + $Image.Length)
        Set-Content -LiteralPath $ConfigPath -Value $text -NoNewline
    }
    $Image = $NewImage
}

# --- Split into registry / repo:tag ------------------------------------------
$RegistryHost = $Image.Split('/')[0]          # genaicr2fkp.azurecr.io
$RegistryName = $RegistryHost.Split('.')[0]   # genaicr2fkp
$RepoAndTag   = $Image.Substring($Image.IndexOf('/') + 1)  # my-hosted-agent:20260612

Write-Host "-> Config:   $ConfigPath"
Write-Host "-> Image:    $Image"
Write-Host "-> Registry: $RegistryName"
Write-Host "-> Context:  $Context"

# --- 1) Ensure the Foundry PROJECT identity can pull from the ACR ------------
# Foundry pulls the image using the PROJECT's system-assigned managed identity
# (NOT the account identity). If it lacks AcrPull, the version fails with
# [ImageError] Failed to pull container image. The registry's ARM-audience AAD
# auth policy must also be enabled for token-based pulls.
function Invoke-EnsurePullPermissions {
    $account = Read-YamlScalar 'accountName'
    $project = Read-YamlScalar 'projectName'
    if (-not $account -or -not $project) {
        Write-Warning 'could not read foundry.accountName/projectName; skipping RBAC.'
        return
    }

    $accountId = az cognitiveservices account list --query "[?name=='$account'].id | [0]" -o tsv 2>$null
    if (-not $accountId) {
        Write-Warning "Foundry account '$account' not found in current subscription; skipping RBAC."
        return
    }
    $projectId = "$accountId/projects/$project"

    $principal = az resource show --ids $projectId --query 'identity.principalId' -o tsv 2>$null
    if (-not $principal) {
        Write-Warning 'could not resolve project managed identity; skipping RBAC.'
        return
    }

    $acrId = az acr show -n $RegistryName --query id -o tsv 2>$null
    if (-not $acrId) {
        Write-Warning "ACR '$RegistryName' not found; skipping RBAC."
        return
    }

    Write-Host "-> Ensuring AcrPull for project identity $principal on $RegistryName"
    az role assignment create `
        --assignee-object-id $principal `
        --assignee-principal-type ServicePrincipal `
        --role AcrPull `
        --scope $acrId *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host '   AcrPull granted.'
    }
    else {
        Write-Host '   AcrPull already present (or insufficient rights to assign).'
    }

    Write-Host '-> Ensuring ACR ARM-audience AAD auth policy is enabled'
    az acr config authentication-as-arm update -r $RegistryName --status enabled *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host '   authentication-as-arm: enabled'
    }
    else {
        Write-Host '   WARN: could not update authentication-as-arm policy (continuing).'
    }
}

if ($env:SKIP_RBAC -ne '1') {
    Invoke-EnsurePullPermissions
}
else {
    Write-Host '-> SKIP_RBAC=1; skipping ACR pull-permission setup.'
}

# --- 2) Build & push the image in ACR ----------------------------------------
if ($env:SKIP_BUILD -ne '1') {
    Write-Host "-> Building and pushing image with 'az acr build'..."
    az acr build `
        --registry $RegistryName `
        --image $RepoAndTag `
        --platform linux/amd64 `
        $Context
    if ($LASTEXITCODE -ne 0) {
        Write-Error 'az acr build failed.'
        exit $LASTEXITCODE
    }
}
else {
    Write-Host '-> SKIP_BUILD=1; skipping ACR build.'
}

# --- 3) Bootstrap venv and deploy the agent version --------------------------
if ($env:SKIP_VENV -eq '1') {
    $Py = $Python
}
else {
    if (-not (Test-Path $VenvDir)) {
        Write-Host "-> Creating virtualenv: $VenvDir"
        & $Python -m venv $VenvDir
        $VenvPython = if ($IsWindows) { Join-Path $VenvDir 'Scripts/python.exe' } else { Join-Path $VenvDir 'bin/python' }
        & $VenvPython -m pip install --upgrade pip --root-user-action=ignore | Out-Null
        Write-Host '-> Installing requirements'
        & $VenvPython -m pip install -r $Requirements --root-user-action=ignore
    }
    $Py = if ($IsWindows) { Join-Path $VenvDir 'Scripts/python.exe' } else { Join-Path $VenvDir 'bin/python' }
}

Write-Host '-> Deploying hosted agent version to Foundry...'
& $Py $Entrypoint $ConfigPath @DeployArgs
exit $LASTEXITCODE
