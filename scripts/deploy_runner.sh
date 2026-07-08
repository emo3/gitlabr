#!/bin/bash

# Deploy a standalone GitLab Runner Helm release for the local gitlabc install.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab-runner}"
GITLAB_HELM_REPO_NAME="${GITLAB_HELM_REPO_NAME:-gitlab}"
GITLAB_HELM_REPO_URL="${GITLAB_HELM_REPO_URL:-https://charts.gitlab.io/}"
RUNNER_CHART_REF="${RUNNER_CHART_REF:-${GITLAB_HELM_REPO_NAME}/gitlab-runner}"
RUNNER_CHART_VERSION="${RUNNER_CHART_VERSION:-}"
RUNNER_VALUES_FILE="${RUNNER_VALUES_FILE:-${PROJECT_ROOT}/.values/gitlab-runner.values.yaml}"
RUNNER_CACHE_SECRET_NAME="${RUNNER_CACHE_SECRET_NAME:-gitlab-runner-garage-cache}"
GARAGE_RELEASE_NAME="${GARAGE_RELEASE_NAME:-dev-garage}"
GARAGE_OBJECT_STORAGE_SECRET="${GARAGE_OBJECT_STORAGE_SECRET:-${GARAGE_RELEASE_NAME}-gitlab-object-storage}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"
WAIT_FOR_RUNNER="${WAIT_FOR_RUNNER:-true}"
RUNNER_TOKEN_VALUE=""

cd "${PROJECT_ROOT}"

function require_tool() {
  local tool="$1"

  if ! command -v "${tool}" > /dev/null 2>&1; then
    echo "ERROR: ${tool} is required but not installed."
    exit 1
  fi
}

function runner_token() {
  if [[ -n "${GITLAB_RUNNER_TOKEN:-}" ]]; then
    printf '%s' "${GITLAB_RUNNER_TOKEN}"
    return 0
  fi

  if [[ -n "${GITLAB_RUNNER_TOKEN_FILE:-}" ]]; then
    if [[ ! -f "${GITLAB_RUNNER_TOKEN_FILE}" ]]; then
      echo "ERROR: GITLAB_RUNNER_TOKEN_FILE does not exist: ${GITLAB_RUNNER_TOKEN_FILE}" >&2
      exit 1
    fi
    tr -d '\n' < "${GITLAB_RUNNER_TOKEN_FILE}"
    return 0
  fi

  echo "ERROR: Set GITLAB_RUNNER_TOKEN or GITLAB_RUNNER_TOKEN_FILE." >&2
  echo "Create a runner in GitLab first, then use its runner authentication token." >&2
  exit 1
}

function validate_boolean() {
  local name="$1"
  local value="$2"

  case "${value}" in
    true|false)
      ;;
    *)
      echo "ERROR: ${name} must be 'true' or 'false'."
      exit 1
      ;;
  esac
}

function base64_decode() {
  if base64 --decode >/dev/null 2>&1 <<< ""; then
    base64 --decode
  else
    base64 -D
  fi
}

function ensure_context() {
  if ! kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1; then
    echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found."
    echo "Run ../gitlabc/ansible-install-k8s-tools-gitlab-deps.yml first, or set KUBE_CONTEXT."
    exit 1
  fi

  kubectl config use-context "${KUBE_CONTEXT}" > /dev/null
}

function ensure_values_file() {
  if [[ -f "${RUNNER_VALUES_FILE}" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "${RUNNER_VALUES_FILE}")"
  cp "${PROJECT_ROOT}/.values/gitlab-runner.example.values.yaml" "${RUNNER_VALUES_FILE}"
  echo "Created ${RUNNER_VALUES_FILE} from the example values."
}

function ensure_helm_repo() {
  if ! helm repo list | awk '{print $1}' | grep -qx "${GITLAB_HELM_REPO_NAME}"; then
    echo "Adding Helm repo '${GITLAB_HELM_REPO_NAME}'..."
    helm repo add "${GITLAB_HELM_REPO_NAME}" "${GITLAB_HELM_REPO_URL}"
  fi

  echo "Updating Helm repo '${GITLAB_HELM_REPO_NAME}'..."
  helm repo update "${GITLAB_HELM_REPO_NAME}"
}

function create_cache_secret() {
  local config
  local access_key
  local secret_key

  if ! kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get secret "${GARAGE_OBJECT_STORAGE_SECRET}" > /dev/null 2>&1; then
    echo "WARNING: Secret '${GARAGE_OBJECT_STORAGE_SECRET}' was not found. Skipping runner cache secret."
    echo "         Run ../gitlabc/scripts/dev_dependencies.sh setup first if you want Garage-backed cache."
    return 0
  fi

  config="$(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get secret "${GARAGE_OBJECT_STORAGE_SECRET}" -o jsonpath='{.data.config}' | base64_decode)"
  access_key="$(awk -F': ' '/^aws_access_key_id:/ {print $2; exit}' <<< "${config}")"
  secret_key="$(awk -F': ' '/^aws_secret_access_key:/ {print $2; exit}' <<< "${config}")"

  if [[ -z "${access_key}" || -z "${secret_key}" ]]; then
    echo "ERROR: Could not extract Garage access keys from '${GARAGE_OBJECT_STORAGE_SECRET}'."
    exit 1
  fi

  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" create secret generic "${RUNNER_CACHE_SECRET_NAME}" \
    --from-literal=accesskey="${access_key}" \
    --from-literal=secretkey="${secret_key}" \
    --dry-run=client -o yaml | kubectl --context "${KUBE_CONTEXT}" apply -f -
}

require_tool kubectl
require_tool helm
validate_boolean WAIT_FOR_RUNNER "${WAIT_FOR_RUNNER}"
RUNNER_TOKEN_VALUE="$(runner_token)"
ensure_context
ensure_values_file
ensure_helm_repo
create_cache_secret

HELM_ARGS=(
  upgrade --install "${RELEASE_NAME}" "${RUNNER_CHART_REF}"
  --kube-context "${KUBE_CONTEXT}"
  --namespace "${NAMESPACE}"
  --create-namespace
  -f "${RUNNER_VALUES_FILE}"
  --set-string "runnerToken=${RUNNER_TOKEN_VALUE}"
)

if [[ -n "${RUNNER_CHART_VERSION}" ]]; then
  HELM_ARGS+=(--version "${RUNNER_CHART_VERSION}")
fi

if [[ "${WAIT_FOR_RUNNER}" == "true" ]]; then
  HELM_ARGS+=(--wait --timeout 300s)
fi

echo "Deploying GitLab Runner release '${RELEASE_NAME}' to namespace '${NAMESPACE}'..."
helm "${HELM_ARGS[@]}"

echo "Runner deploy complete."
echo "Check status: bash scripts/check_runner.sh"
