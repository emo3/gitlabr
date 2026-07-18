#!/bin/bash

# Print focused status for the standalone GitLab Runner release.

set -eo pipefail
[[ "${TRACE}" ]] && set -x

NAMESPACE="${NAMESPACE:-gitlab}"
RELEASE_NAME="${RELEASE_NAME:-gitlab-runner}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitlab-dev}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${K3D_CLUSTER_NAME}}"
STRICT=false

function usage() {
  cat <<'USAGE'
Usage: bash scripts/check_runner.sh [-s] [-h]

Prints focused runner diagnostics.

Options:
  -s  Exit non-zero when the Helm release or runner deployment is not ready.
  -h  Show this help.
USAGE
}

while getopts ":sh" opt; do
  case "${opt}" in
    s)
      STRICT=true
      ;;
    h)
      usage
      exit 0
      ;;
    \?)
      echo "ERROR: Unknown argument: -${OPTARG}"
      usage
      exit 1
      ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -gt 0 ]]; then
  echo "ERROR: Unexpected positional argument: $1"
  usage
  exit 1
fi

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

if [[ "${STRICT}" == "true" ]]; then
  helm status "${RELEASE_NAME}" -n "${NAMESPACE}" --kube-context "${KUBE_CONTEXT}" > /dev/null
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" rollout status \
    "deployment/${RELEASE_NAME}" --timeout=30s > /dev/null
  echo "Runner release and deployment are ready."
fi
