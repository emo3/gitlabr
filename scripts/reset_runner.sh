#!/bin/bash

# Remove the standalone GitLab Runner Helm release.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab-runner}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"

if ! kubectl config get-contexts "${KUBE_CONTEXT}" > /dev/null 2>&1; then
  echo "ERROR: Kubernetes context '${KUBE_CONTEXT}' was not found."
  exit 1
fi

helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --kube-context "${KUBE_CONTEXT}" --ignore-not-found
echo "Runner release '${RELEASE_NAME}' removed from namespace '${NAMESPACE}'."
