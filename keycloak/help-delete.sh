#!/usr/bin/env bash
# help-delete.sh — completely remove the Keycloak stack only.
#
# Removes:
#   - Argo CD Application keycloak-apps (App-of-Apps root)
#   - Keycloak child Applications (with cascade finalizer)
#   - Keycloak + PostgresCluster CRs
#   - Namespaces keycloak, crunchy-operator
#   - AppProject appkeycloak
#
# Does NOT remove:
#   - Logging stack / logging-apps
#   - AppProject cluster-config (shared with logging)
#   - Git repository Secret git-repo (shared; optional below)
#   - OpenShift GitOps operator
#
# Prerequisites:
#   oc logged in, or kubeconfig at $HOME/ocpkubeconfig
#
# Usage (from repo root or this directory):
#   ./keycloak/help-delete.sh
#   KUBECONFIG=$HOME/ocpkubeconfig ./keycloak/help-delete.sh
#   DELETE_GIT_SECRET=true ./keycloak/help-delete.sh

set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/ocpkubeconfig}"
NS=openshift-gitops
DELETE_GIT_SECRET="${DELETE_GIT_SECRET:-false}"

if [[ ! -f "${KUBECONFIG}" ]]; then
  echo "ERROR: kubeconfig not found at ${KUBECONFIG}" >&2
  echo "  oc config view --raw > \"\${HOME}/ocpkubeconfig\"" >&2
  exit 1
fi

echo "==> Using KUBECONFIG=${KUBECONFIG}"
oc whoami >/dev/null

# ---------------------------------------------------------------------------
# 1) Cascade-delete Keycloak Argo Applications (root + children)
# ---------------------------------------------------------------------------
echo "==> Deleting Keycloak Argo CD Applications (cascade)..."

APPS=(
  keycloak-apps
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
echo "==> Deleting Keycloak / Postgres CRs..."

oc delete keycloak --all -n keycloak --ignore-not-found --wait=true
oc delete postgrescluster --all -n keycloak --ignore-not-found --wait=true

# ---------------------------------------------------------------------------
# 3) Delete Keycloak namespaces
# ---------------------------------------------------------------------------
echo "==> Deleting Keycloak namespaces..."

oc delete ns keycloak crunchy-operator --ignore-not-found --wait=true

# ---------------------------------------------------------------------------
# 4) Clean Keycloak AppProject (and optional shared Git Secret)
# ---------------------------------------------------------------------------
echo "==> Deleting AppProject appkeycloak..."

oc delete appproject appkeycloak -n "${NS}" --ignore-not-found

if [[ "${DELETE_GIT_SECRET}" == "true" ]]; then
  echo "==> Deleting Git repository Secret (DELETE_GIT_SECRET=true)..."
  echo "    Warning: logging-apps also uses this Secret if it shares the same Git URL."
  oc delete secret git-repo keycloak-git-repo -n "${NS}" --ignore-not-found
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo "==> Keycloak Applications (should be gone):"
for app in "${APPS[@]}"; do
  if oc get application "${app}" -n "${NS}" >/dev/null 2>&1; then
    echo "  STILL PRESENT: ${app}"
  else
    echo "  gone: ${app}"
  fi
done

echo "==> Keycloak namespaces (should be NotFound):"
for n in keycloak crunchy-operator; do
  if oc get ns "${n}" >/dev/null 2>&1; then
    echo "  STILL PRESENT: ${n}"
  else
    echo "  gone: ${n}"
  fi
done

echo
echo "Done. Redeploy Keycloak with:"
echo "  ansible-playbook deploy-gitops.yaml"
echo "  # or Keycloak-only:"
echo "  ansible-playbook deploy-gitops-keycload.yaml"
echo
echo "Optional: also remove shared Git Secret with:"
echo "  DELETE_GIT_SECRET=true ./keycloak/help-delete.sh"
