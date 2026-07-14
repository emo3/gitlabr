#!/bin/bash

# Reconcile the standalone GitLab Runner and restart it to recover from an
# offline runner or jobs that remain pending. Safe to run repeatedly.

set -euo pipefail
[[ "${TRACE:-}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab-runner}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"
RUNNER_TOKEN_FILE="${GITLAB_RUNNER_TOKEN_FILE:-${PROJECT_ROOT}/.secrets/gitlab-runner-token}"
REGISTRY_TOKEN_FILE="${GITLAB_REGISTRY_TOKEN_FILE:-${PROJECT_ROOT}/.secrets/gitlab-registry-token}"
ROLL_OUT_TIMEOUT="${ROLL_OUT_TIMEOUT:-300s}"

require_file() {
  local file="$1"
  local name="$2"

  if [[ ! -s "${file}" ]]; then
    echo "ERROR: ${name} is missing or empty: ${file}" >&2
    exit 1
  fi
}

if ! kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1; then
  echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found." >&2
  exit 1
fi

require_file "${RUNNER_TOKEN_FILE}" "Runner token file"
require_file "${REGISTRY_TOKEN_FILE}" "Registry token file"

echo "Reconciling runner release '${RELEASE_NAME}'..."
GITLAB_RUNNER_TOKEN_FILE="${RUNNER_TOKEN_FILE}" \
GITLAB_REGISTRY_TOKEN_FILE="${REGISTRY_TOKEN_FILE}" \
  bash "${SCRIPT_DIR}/deploy_runner.sh"

echo "Restarting runner deployment to refresh its GitLab polling connection..."
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" rollout restart \
  "deployment/${RELEASE_NAME}"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" rollout status \
  "deployment/${RELEASE_NAME}" --timeout="${ROLL_OUT_TIMEOUT}"

echo "Runner recovery complete."
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods \
  -l "app=gitlab-runner,release=${RELEASE_NAME}"
