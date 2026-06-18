#!/usr/bin/env bash
#
# Wrapper around src/deploy_code_agent.py.
#
# Deploys a CODE-BASED Foundry Hosted Agent: no Docker image and no ACR. The
# script zips the source folder (agent.sourceDir) and uploads it; Foundry builds
# and runs it for you and injects FOUNDRY_PROJECT_ENDPOINT automatically.
#
# - Creates/uses a local .venv and installs requirements.txt on first run.
# - Forwards all arguments to the Python script.
#
# Usage:
#   scripts/deploy-code-agent.sh configs/code-agent.yaml
#   scripts/deploy-code-agent.sh configs/code-agent.yaml --invoke "Are you ready?"
#   scripts/deploy-code-agent.sh configs/code-agent.yaml --delete
#
# Env vars:
#   PYTHON     Python interpreter to bootstrap the venv (default: python3)
#   VENV_DIR   Virtualenv location (default: <repo>/.venv)
#   SKIP_VENV  If set to 1, run with the current interpreter (no venv).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PYTHON="${PYTHON:-python3}"
VENV_DIR="${VENV_DIR:-${REPO_ROOT}/.venv}"
REQUIREMENTS="${REPO_ROOT}/requirements.txt"
ENTRYPOINT="${REPO_ROOT}/src/deploy_code_agent.py"

CONFIG="${1:-configs/code-agent.yaml}"
shift || true
DEPLOY_ARGS=("$@")

CONFIG_PATH="${CONFIG}"
[[ -f "${CONFIG_PATH}" ]] || CONFIG_PATH="${REPO_ROOT}/${CONFIG}"
if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "ERROR: config not found: ${CONFIG}" >&2
  exit 1
fi

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

exec "${PY}" "${ENTRYPOINT}" "${CONFIG_PATH}" "${DEPLOY_ARGS[@]}"
