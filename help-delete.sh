#!/usr/bin/env bash
# help-delete.sh — completely remove logging + Keycloak App-of-Apps stacks from the cluster.
#
# Removes:
#   - Argo CD Applications (roots + children), with cascade finalizer
#   - Blocking CRs (LokiStack, ClusterLogForwarder, UIPlugin, Keycloak, PostgresCluster)
#   - Stack namespaces
#   - AppProjects cluster-config / applogging / appkeycloak
#   - Git repository Secret keycloak-git-repo
#
# Does NOT remove:
#   - OpenShift GitOps operator / openshift-gitops instance
#   - S4 (s4 namespace) — optional block at the bottom
#
# Prerequisites:
#   oc logged in, or kubeconfig at /tmp/ocpkubeconfig
#
# Usage:
#   ./help-delete.sh
#   KUBECONFIG=/tmp/ocpkubeconfig ./help-delete.sh
#   DELETE_S4=true ./help-delete.sh

set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/tmp/ocpkubeconfig}"
NS=openshift-gitops
DELETE_S4="${DELETE_S4:-false}"

if [[ ! -f "${KUBECONFIG}" ]]; then
  echo "ERROR: kubeconfig not found at ${KUBECONFIG}" >&2
  echo "  oc config view --raw > /tmp/ocpkubeconfig" >&2
  exit 1
fi

echo "==> Using KUBECONFIG=${KUBECONFIG}"
oc whoami >/dev/null

# ---------------------------------------------------------------------------
# 1) Cascade-delete Argo Applications (roots + children)
# ---------------------------------------------------------------------------
echo "==> Deleting Argo CD Applications (cascade)..."

APPS=(
  cluster-apps
  logging-apps
  keycloak-apps
  logginginstance
  loki-instance
  coo
  logging
  lokioperator
  keycloak
  keycloak-postgres
  rhbk-operator
  crunchy-operator
)

for app in "${APPS[@]}"; do
  if ! oc get application "${app}" -n "${NS}" >/dev/null 2>&1; then
    continue
  fi
  echo "  - ${app}"
  oc patch application "${app}" -n "${NS}" --type merge \
    -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}' \
    >/dev/null 2>&1 || true
  oc delete application "${app}" -n "${NS}" --wait=true --ignore-not-found
done

# ---------------------------------------------------------------------------
# 2) Delete CRs that can block namespace deletion
# ---------------------------------------------------------------------------
echo "==> Deleting blocking CRs..."

oc delete lokistack --all -n openshift-logging --ignore-not-found --wait=true
oc delete clusterlogforwarder --all -n openshift-logging --ignore-not-found --wait=true
oc delete uiplugin --all --ignore-not-found --wait=true
oc delete keycloak --all -n keycloak --ignore-not-found --wait=true
oc delete postgrescluster --all -n keycloak --ignore-not-found --wait=true

# ---------------------------------------------------------------------------
# 3) Delete stack namespaces
# ---------------------------------------------------------------------------
echo "==> Deleting stack namespaces..."

oc delete ns \
  openshift-logging \
  openshift-operators-redhat \
  openshift-cluster-observability-operator \
  keycloak \
  crunchy-operator \
  --ignore-not-found --wait=true

# ---------------------------------------------------------------------------
# 4) Clean AppProjects + Git repo Secret
# ---------------------------------------------------------------------------
echo "==> Deleting AppProjects and Git repository Secret..."

oc delete appproject cluster-config applogging appkeycloak \
  -n "${NS}" --ignore-not-found
oc delete secret keycloak-git-repo -n "${NS}" --ignore-not-found

# ---------------------------------------------------------------------------
# Optional: S4
# ---------------------------------------------------------------------------
if [[ "${DELETE_S4}" == "true" ]]; then
  echo "==> Deleting S4 (DELETE_S4=true)..."
  oc delete ns s4 --ignore-not-found --wait=true
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo "==> Remaining Applications in ${NS}:"
oc get applications -n "${NS}" 2>/dev/null || echo "  (none or CRD missing)"

echo "==> Stack namespaces (should be NotFound):"
for n in openshift-logging openshift-operators-redhat \
  openshift-cluster-observability-operator keycloak crunchy-operator; do
  if oc get ns "${n}" >/dev/null 2>&1; then
    echo "  STILL PRESENT: ${n}"
  else
    echo "  gone: ${n}"
  fi
done

echo
echo "Done. Redeploy with:"
echo "  ansible-playbook deploy-gitops.yaml"
echo
echo "Optional: also remove S4 with DELETE_S4=true ./help-delete.sh"
