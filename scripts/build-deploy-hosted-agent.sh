#!/usr/bin/env bash
#
# Build the hosted-agent container, push it to ACR, then create the Foundry
# hosted-agent version that runs it.
#
# Steps:
#   1. Read agent.image from the config (registry / repo:tag).
#   2. Ensure the Foundry PROJECT managed identity can pull from the ACR
#      (grant AcrPull + enable the registry's ARM-audience AAD auth policy).
#      This is the identity Foundry uses to pull the image; without it the
#      version fails with [ImageError] Failed to pull container image.
#   3. az acr build   -> builds the image in ACR and pushes it (linux/amd64).
#   4. src/deploy_hosted_agent.py -> creates the agent version in Foundry.
#
# Usage:
#   scripts/build-deploy-hosted-agent.sh [CONFIG] [-- EXTRA_DEPLOY_ARGS...]
#
# Examples:
#   scripts/build-deploy-hosted-agent.sh
#   scripts/build-deploy-hosted-agent.sh configs/hosted-agent.yaml
#   scripts/build-deploy-hosted-agent.sh configs/hosted-agent.yaml --invoke "Hello"
#   NEW_TAG=1 scripts/build-deploy-hosted-agent.sh   # stamp a fresh timestamp tag
#
# Env vars:
#   CONTEXT     Docker build context (default: <repo>/agents/hosted-agent)
#   NEW_TAG     If set to 1, replace the image tag with a UTC timestamp and
#               rewrite the config before building/deploying.
#   PYTHON      Python interpreter to bootstrap the venv (default: python3)
#   VENV_DIR    Virtualenv location (default: <repo>/.venv)
#   SKIP_VENV   If set to 1, run deploy with the current interpreter (no venv).
#   SKIP_BUILD  If set to 1, skip the ACR build and only deploy.
#   SKIP_RBAC   If set to 1, skip ensuring ACR pull permissions for the project
#               identity (use when you don't have role-assignment rights).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG="${1:-configs/hosted-agent.yaml}"
shift || true
# Drop a leading "--" so callers can pass extra deploy args after it.
[[ "${1:-}" == "--" ]] && shift || true
DEPLOY_ARGS=("$@")

CONFIG_PATH="${CONFIG}"
[[ -f "${CONFIG_PATH}" ]] || CONFIG_PATH="${REPO_ROOT}/${CONFIG}"
if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "ERROR: config not found: ${CONFIG}" >&2
  exit 1
fi

CONTEXT="${CONTEXT:-${REPO_ROOT}/agents/hosted-agent}"
PYTHON="${PYTHON:-python3}"
VENV_DIR="${VENV_DIR:-${REPO_ROOT}/.venv}"
REQUIREMENTS="${REPO_ROOT}/requirements.txt"
ENTRYPOINT="${REPO_ROOT}/src/deploy_hosted_agent.py"

# --- Read a scalar value from the config -------------------------------------
read_image() {
  sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "${CONFIG_PATH}" | head -n1 \
    | sed 's/[[:space:]]*#.*$//' | tr -d '"'"'"''
}
read_yaml_scalar() {
  # $1 = key name (e.g. accountName); returns first matching scalar value.
  sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "${CONFIG_PATH}" | head -n1 \
    | sed 's/[[:space:]]*#.*$//' | tr -d '"'"'"''
}
IMAGE="$(read_image)"
if [[ -z "${IMAGE}" ]]; then
  echo "ERROR: could not read 'agent.image' from ${CONFIG_PATH}" >&2
  exit 1
fi

# --- Optionally stamp a fresh immutable tag ----------------------------------
if [[ "${NEW_TAG:-0}" == "1" ]]; then
  STAMP="$(date -u +%Y%m%d%H%M%S)"
  IMAGE_BASE="${IMAGE%:*}"
  NEW_IMAGE="${IMAGE_BASE}:${STAMP}"
  echo "-> Stamping new tag: ${NEW_IMAGE}"
  # Replace the existing image line in the config.
  python3 - "$CONFIG_PATH" "$IMAGE" "$NEW_IMAGE" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read().replace(old, new, 1)
open(path, "w", encoding="utf-8").write(text)
PY
  IMAGE="${NEW_IMAGE}"
fi

# --- Split into registry / repo:tag ------------------------------------------
REGISTRY_HOST="${IMAGE%%/*}"          # genaicr2fkp.azurecr.io
REGISTRY_NAME="${REGISTRY_HOST%%.*}"  # genaicr2fkp
REPO_AND_TAG="${IMAGE#*/}"            # my-hosted-agent:20260612

echo "-> Config:   ${CONFIG_PATH}"
echo "-> Image:    ${IMAGE}"
echo "-> Registry: ${REGISTRY_NAME}"
echo "-> Context:  ${CONTEXT}"

# --- 1) Ensure the Foundry PROJECT identity can pull from the ACR ------------
# Foundry pulls the image using the PROJECT's system-assigned managed identity
# (NOT the account identity). If it lacks AcrPull, the version fails with
# [ImageError] Failed to pull container image. The registry's ARM-audience AAD
# auth policy must also be enabled for token-based pulls.
ensure_pull_permissions() {
  local account project account_id project_id principal acr_id
  account="$(read_yaml_scalar accountName)"
  project="$(read_yaml_scalar projectName)"
  if [[ -z "${account}" || -z "${project}" ]]; then
    echo "-> WARN: could not read foundry.accountName/projectName; skipping RBAC." >&2
    return 0
  fi

  account_id="$(az cognitiveservices account list \
    --query "[?name=='${account}'].id | [0]" -o tsv 2>/dev/null)"
  if [[ -z "${account_id}" ]]; then
    echo "-> WARN: Foundry account '${account}' not found in current subscription; skipping RBAC." >&2
    return 0
  fi
  project_id="${account_id}/projects/${project}"

  principal="$(az resource show --ids "${project_id}" \
    --query 'identity.principalId' -o tsv 2>/dev/null)"
  if [[ -z "${principal}" ]]; then
    echo "-> WARN: could not resolve project managed identity; skipping RBAC." >&2
    return 0
  fi

  acr_id="$(az acr show -n "${REGISTRY_NAME}" --query id -o tsv 2>/dev/null)"
  if [[ -z "${acr_id}" ]]; then
    echo "-> WARN: ACR '${REGISTRY_NAME}' not found; skipping RBAC." >&2
    return 0
  fi

  echo "-> Ensuring AcrPull for project identity ${principal} on ${REGISTRY_NAME}"
  if az role assignment create \
        --assignee-object-id "${principal}" \
        --assignee-principal-type ServicePrincipal \
        --role AcrPull \
        --scope "${acr_id}" >/dev/null 2>&1; then
    echo "   AcrPull granted."
  else
    echo "   AcrPull already present (or insufficient rights to assign)."
  fi

  echo "-> Ensuring ACR ARM-audience AAD auth policy is enabled"
  az acr config authentication-as-arm update -r "${REGISTRY_NAME}" \
    --status enabled >/dev/null 2>&1 \
    && echo "   authentication-as-arm: enabled" \
    || echo "   WARN: could not update authentication-as-arm policy (continuing)."
}

if [[ "${SKIP_RBAC:-0}" != "1" ]]; then
  ensure_pull_permissions
else
  echo "-> SKIP_RBAC=1; skipping ACR pull-permission setup."
fi

# --- 2) Build & push the image in ACR ----------------------------------------
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "-> Building and pushing image with 'az acr build'..."
  az acr build \
    --registry "${REGISTRY_NAME}" \
    --image "${REPO_AND_TAG}" \
    --platform linux/amd64 \
    "${CONTEXT}"
else
  echo "-> SKIP_BUILD=1; skipping ACR build."
fi

# --- 3) Bootstrap venv and deploy the agent version --------------------------
if [[ "${SKIP_VENV:-0}" == "1" ]]; then
  PY="${PYTHON}"
else
  if [[ ! -d "${VENV_DIR}" ]]; then
    echo "-> Creating virtualenv: ${VENV_DIR}"
    "${PYTHON}" -m venv "${VENV_DIR}"
    "${VENV_DIR}/bin/python" -m pip install --upgrade pip >/dev/null
    echo "-> Installing requirements"
    "${VENV_DIR}/bin/python" -m pip install -r "${REQUIREMENTS}"
  fi
  PY="${VENV_DIR}/bin/python"
fi

echo "-> Deploying hosted agent version to Foundry..."
exec "${PY}" "${ENTRYPOINT}" "${CONFIG_PATH}" "${DEPLOY_ARGS[@]}"
