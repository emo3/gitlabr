#!/bin/bash

# Print focused status for the standalone GitLab Runner release.

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

echo "== Helm release =="
helm status "${RELEASE_NAME}" -n "${NAMESPACE}" --kube-context "${KUBE_CONTEXT}" || true

echo ""
echo "== Runner pods =="
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods \
  -l "app=gitlab-runner,release=${RELEASE_NAME}" -o wide || true

echo ""
echo "== Runner deployment =="
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get deployment \
  -l "app=gitlab-runner,release=${RELEASE_NAME}" || true

echo ""
echo "== Recent runner events =="
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get events \
  --sort-by=.lastTimestamp | tail -20 || true
