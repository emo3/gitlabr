#!/bin/bash

# Remove the standalone GitLab Runner Helm release.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab-runner}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"

function usage() {
  cat <<'USAGE'
Usage: bash scripts/reset_runner.sh [-h]

Removes the standalone GitLab Runner Helm release. Local token files and shared
registry/cache secrets are retained.
USAGE
}

while getopts ":h" opt; do
  case "${opt}" in
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
  echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found."
  exit 1
fi

helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --kube-context "${KUBE_CONTEXT}" --ignore-not-found
echo "Runner release '${RELEASE_NAME}' removed from namespace '${NAMESPACE}'."
