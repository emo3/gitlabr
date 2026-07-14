#!/bin/bash

# Deploy a standalone GitLab Runner Helm release for the local gitlabc install.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CODE_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab-runner}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.127.0.0.1.nip.io}"
GITLAB_REGISTRY_HOST="${GITLAB_REGISTRY_HOST:-registry.127.0.0.1.nip.io}"
GITLAB_REGISTRY_PULL_SECRET="${GITLAB_REGISTRY_PULL_SECRET:-gitlab-registry-pull}"
GITLAB_REGISTRY_USERNAME="${GITLAB_REGISTRY_USERNAME:-oauth2}"
GITLAB_REGISTRY_EMAIL="${GITLAB_REGISTRY_EMAIL:-gitlab-runner-local@example.invalid}"
CREATE_REGISTRY_PULL_SECRET="${CREATE_REGISTRY_PULL_SECRET:-true}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${CODE_ROOT}/.glab-config}"
GLAB_CONFIG_FILE="${GLAB_CONFIG_FILE:-${XDG_CONFIG_HOME}/glab-cli/config.yml}"
GITLAB_HELM_REPO_NAME="${GITLAB_HELM_REPO_NAME:-gitlab}"
GITLAB_HELM_REPO_URL="${GITLAB_HELM_REPO_URL:-https://charts.gitlab.io/}"
RUNNER_CHART_REF="${RUNNER_CHART_REF:-${GITLAB_HELM_REPO_NAME}/gitlab-runner}"
RUNNER_CHART_VERSION="${RUNNER_CHART_VERSION:-}"
RUNNER_VALUES_FILE="${RUNNER_VALUES_FILE:-${PROJECT_ROOT}/.values/gitlab-runner.values.yaml}"
GITLAB_INGRESS_SERVICE="${GITLAB_INGRESS_SERVICE:-gitlab-nginx-ingress-controller}"
GITLAB_WEBSERVICE_INGRESS="${GITLAB_WEBSERVICE_INGRESS:-gitlab-webservice-default}"
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

function registry_token() {
  if [[ -n "${GITLAB_REGISTRY_TOKEN:-}" ]]; then
    printf '%s' "${GITLAB_REGISTRY_TOKEN}"
    return 0
  fi

  if [[ -n "${GITLAB_REGISTRY_TOKEN_FILE:-}" ]]; then
    if [[ ! -f "${GITLAB_REGISTRY_TOKEN_FILE}" ]]; then
      echo "ERROR: GITLAB_REGISTRY_TOKEN_FILE does not exist: ${GITLAB_REGISTRY_TOKEN_FILE}" >&2
      exit 1
    fi
    tr -d '\n' < "${GITLAB_REGISTRY_TOKEN_FILE}"
    return 0
  fi

  if [[ -f "${GLAB_CONFIG_FILE}" ]]; then
    awk -v host="${GITLAB_HOST}" '
      $1 == host ":" {inhost = 1; next}
      inhost && $1 == "token:" {print $2; exit}
    ' "${GLAB_CONFIG_FILE}"
    return 0
  fi

  return 0
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

function render_runner_values() {
  local ingress_ip
  local external_gitlab_host
  local rendered_values

  ingress_ip="$(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get service "${GITLAB_INGRESS_SERVICE}" -o jsonpath='{.spec.clusterIP}')"
  if [[ -z "${ingress_ip}" || "${ingress_ip}" == "None" ]]; then
    echo "ERROR: Could not resolve ClusterIP for service '${GITLAB_INGRESS_SERVICE}'." >&2
    exit 1
  fi

  external_gitlab_host="$(kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get ingress "${GITLAB_WEBSERVICE_INGRESS}" -o jsonpath='{.spec.rules[0].host}')"
  if [[ -z "${external_gitlab_host}" ]]; then
    echo "ERROR: Could not resolve the GitLab hostname from ingress '${GITLAB_WEBSERVICE_INGRESS}'." >&2
    exit 1
  fi

  rendered_values="$(mktemp)"
  sed \
    -e "s/GITLAB_INGRESS_CLUSTER_IP/${ingress_ip}/g" \
    -e "s/GITLAB_EXTERNAL_HOSTNAME/${external_gitlab_host}/g" \
    "${RUNNER_VALUES_FILE}" > "${rendered_values}"
  printf '%s' "${rendered_values}"
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

function create_registry_pull_secret() {
  local token

  if [[ "${CREATE_REGISTRY_PULL_SECRET}" != "true" ]]; then
    return 0
  fi

  token="$(registry_token)"
  if [[ -z "${token}" ]]; then
    echo "ERROR: Could not find a registry token for ${GITLAB_HOST}."
    echo "Set GITLAB_REGISTRY_TOKEN, GITLAB_REGISTRY_TOKEN_FILE, or run glab auth login with XDG_CONFIG_HOME=${XDG_CONFIG_HOME}."
    exit 1
  fi

  kubectl --context "${KUBE_CONTEXT}" create namespace "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl --context "${KUBE_CONTEXT}" apply -f -

  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" create secret docker-registry "${GITLAB_REGISTRY_PULL_SECRET}" \
    --docker-server="${GITLAB_REGISTRY_HOST}" \
    --docker-username="${GITLAB_REGISTRY_USERNAME}" \
    --docker-password="${token}" \
    --docker-email="${GITLAB_REGISTRY_EMAIL}" \
    --dry-run=client -o yaml | kubectl --context "${KUBE_CONTEXT}" apply -f -
}

require_tool kubectl
require_tool helm
validate_boolean WAIT_FOR_RUNNER "${WAIT_FOR_RUNNER}"
validate_boolean CREATE_REGISTRY_PULL_SECRET "${CREATE_REGISTRY_PULL_SECRET}"
RUNNER_TOKEN_VALUE="$(runner_token)"
ensure_context
ensure_values_file
ensure_helm_repo
create_cache_secret
create_registry_pull_secret
RENDERED_RUNNER_VALUES_FILE="$(render_runner_values)"
trap 'rm -f "${RENDERED_RUNNER_VALUES_FILE}"' EXIT

HELM_ARGS=(
  upgrade --install "${RELEASE_NAME}" "${RUNNER_CHART_REF}"
  --kube-context "${KUBE_CONTEXT}"
  --namespace "${NAMESPACE}"
  --create-namespace
  -f "${RENDERED_RUNNER_VALUES_FILE}"
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
