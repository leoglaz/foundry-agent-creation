#!/usr/bin/env bash
#
# Build the hosted-agent container, push it to ACR, then create the Foundry
# hosted-agent version that runs it.
#
# Steps:
#   1. Read agent.image from the config (registry / repo:tag).
#   2. az acr build   -> builds the image in ACR and pushes it (linux/amd64).
#   3. src/deploy_hosted_agent.py -> creates the agent version in Foundry.
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

# --- Read the image reference from the config --------------------------------
read_image() {
  sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "${CONFIG_PATH}" | head -n1 \
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

# --- 1) Build & push the image in ACR ----------------------------------------
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

# --- 2) Bootstrap venv and deploy the agent version --------------------------
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
