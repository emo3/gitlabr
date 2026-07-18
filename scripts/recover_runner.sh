#!/bin/bash

# Reconcile the standalone GitLab Runner and restart it to recover from an
# offline runner or jobs that remain pending. Safe to run repeatedly.

set -euo pipefail
[[ "${TRACE:-}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUNNER_ENV_FILE="${RUNNER_ENV_FILE:-${PROJECT_ROOT}/.runner.env}"
if [[ -f "${RUNNER_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${RUNNER_ENV_FILE}"
fi

cd "${PROJECT_ROOT}"

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab-runner}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"
RUNNER_TOKEN_FILE="${GITLAB_RUNNER_TOKEN_FILE:-${PROJECT_ROOT}/.secrets/gitlab-runner-token}"
REGISTRY_TOKEN_FILE="${GITLAB_REGISTRY_TOKEN_FILE:-${PROJECT_ROOT}/.secrets/gitlab-registry-token}"
REGISTRY_USERNAME_FILE="${GITLAB_REGISTRY_USERNAME_FILE:-${PROJECT_ROOT}/.secrets/gitlab-registry-username}"
ROLL_OUT_TIMEOUT="${ROLL_OUT_TIMEOUT:-300s}"
FORCE=false

function usage() {
  cat <<'USAGE'
Usage: bash scripts/recover_runner.sh [-f] [-h]

Checks the Runner first. If it is healthy, no change is made unless -f is used.

Options:
  -f  Reconcile and restart the Runner even when it is already healthy.
  -h  Show this help.
USAGE
}

require_file() {
  local file="$1"
  local name="$2"

  if [[ ! -s "${file}" ]]; then
    echo "ERROR: ${name} is missing or empty: ${file}" >&2
    exit 1
  fi
}

while getopts ":fh" opt; do
  case "${opt}" in
    f)
      FORCE=true
      ;;
    h)
      usage
      exit 0
      ;;
    \?)
      echo "ERROR: Unknown argument: -${OPTARG}" >&2
      usage
      exit 1
      ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -gt 0 ]]; then
  echo "ERROR: Unexpected positional argument: $1" >&2
  usage
  exit 1
fi

if ! kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1; then
  echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found." >&2
  exit 1
fi

if bash "${SCRIPT_DIR}/check_runner.sh" -s; then
  if [[ "${FORCE}" != "true" ]]; then
    echo "Runner is already healthy; no recovery action was taken. Use -f to force a restart."
    exit 0
  fi
  echo "Runner is healthy; forcing recovery as requested."
fi

require_file "${RUNNER_TOKEN_FILE}" "Runner token file"
require_file "${REGISTRY_TOKEN_FILE}" "Registry token file"
require_file "${REGISTRY_USERNAME_FILE}" "Registry username file"

echo "Reconciling runner release '${RELEASE_NAME}'..."
GITLAB_RUNNER_TOKEN_FILE="${RUNNER_TOKEN_FILE}" \
GITLAB_REGISTRY_TOKEN_FILE="${REGISTRY_TOKEN_FILE}" \
GITLAB_REGISTRY_USERNAME_FILE="${REGISTRY_USERNAME_FILE}" \
  bash "${SCRIPT_DIR}/deploy_runner.sh"

echo "Restarting runner deployment to refresh its GitLab polling connection..."
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" rollout restart \
  "deployment/${RELEASE_NAME}"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" rollout status \
  "deployment/${RELEASE_NAME}" --timeout="${ROLL_OUT_TIMEOUT}"

echo "Runner recovery complete."
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods \
  -l "app=gitlab-runner,release=${RELEASE_NAME}"
