#!/usr/bin/env bash
# Deploy or update Keycloak stack (operators -> Postgres -> TLS/Keycloak) in a safe order.
# Usage (from repo root):
#   ./keycloak/deploy-keycloak.sh
#   ./keycloak/deploy-keycloak.sh overlays/lab
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="${1:-overlays/lab}"
KC_NS="keycloak"

if [[ "${OVERLAY}" != "overlays/lab" ]]; then
  echo "ERROR: unsupported overlay '${OVERLAY}' (use overlays/lab)" >&2
  exit 1
fi

echo "==> 1/4 Crunchy Postgres operator"
oc apply -k "${REPO_ROOT}/keycloak/crunchy/operator/${OVERLAY}"

echo "==> Wait for PostgresCluster CRD"
oc wait --for=condition=Established \
  crd/postgresclusters.postgres-operator.crunchydata.com \
  --timeout=300s

echo "==> 2/4 Keycloak namespace + RHBK operator"
oc apply -k "${REPO_ROOT}/keycloak/operator/${OVERLAY}"

echo "==> Wait for Keycloak CRD"
oc wait --for=condition=Established \
  crd/keycloaks.k8s.keycloak.org \
  --timeout=300s

echo "==> 3/4 PostgresCluster (creates keycloak-postgres-pguser-keycloak)"
oc apply -k "${REPO_ROOT}/keycloak/crunchy/instance/${OVERLAY}"

echo "==> Wait for Crunchy user Secret in ${KC_NS}"
# Secret is created asynchronously by the Crunchy operator.
for i in $(seq 1 60); do
  if oc get secret keycloak-postgres-pguser-keycloak -n "${KC_NS}" >/dev/null 2>&1; then
    echo "Secret keycloak-postgres-pguser-keycloak is present"
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "ERROR: timed out waiting for secret/keycloak-postgres-pguser-keycloak in ${KC_NS}" >&2
    echo "Check: oc get postgrescluster -n ${KC_NS}; oc get pods -n ${KC_NS}" >&2
    exit 1
  fi
  sleep 5
done

echo "==> Wait for Postgres primary Service"
for i in $(seq 1 60); do
  if oc get svc keycloak-postgres-primary -n "${KC_NS}" >/dev/null 2>&1; then
    echo "Service keycloak-postgres-primary is present"
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "ERROR: timed out waiting for svc/keycloak-postgres-primary in ${KC_NS}" >&2
    exit 1
  fi
  sleep 5
done

echo "==> 4/4 Keycloak instance (+ TLS secret from secretGenerator)"
TLS_CRT="${REPO_ROOT}/keycloak/instance/${OVERLAY}/tls.crt"
TLS_KEY="${REPO_ROOT}/keycloak/instance/${OVERLAY}/tls.key"
BYO_CERT="${KEYCLOAK_TLS_CERT_FILE:-}"
BYO_KEY="${KEYCLOAK_TLS_KEY_FILE:-}"
GENERATE_TLS="${GENERATE_TLS:-true}"

if [[ ! -f "${TLS_CRT}" || ! -f "${TLS_KEY}" ]]; then
  if [[ -n "${BYO_CERT}" || -n "${BYO_KEY}" ]]; then
    echo "ERROR: TLS PEMs missing under ${OVERLAY} but BYO cert mode is set." >&2
    echo "       Run ./configure-keycloak-overlays.sh with KEYCLOAK_TLS_CERT_FILE / KEYCLOAK_TLS_KEY_FILE," >&2
    echo "       or copy signed tls.crt + tls.key into keycloak/instance/${OVERLAY}/" >&2
    exit 1
  fi
  if [[ "${GENERATE_TLS}" == "false" ]]; then
    echo "ERROR: TLS PEMs missing and GENERATE_TLS=false (will not auto-generate)." >&2
    echo "       Place signed tls.crt + tls.key in keycloak/instance/${OVERLAY}/," >&2
    echo "       or set KEYCLOAK_TLS_CERT_FILE / KEYCLOAK_TLS_KEY_FILE and run configure," >&2
    echo "       or re-run with GENERATE_TLS=true for a self-signed lab cert." >&2
    exit 1
  fi
  echo "TLS files missing; generating with generate-tls.sh"
  "${REPO_ROOT}/keycloak/instance/${OVERLAY}/generate-tls.sh"
fi
oc apply -k "${REPO_ROOT}/keycloak/instance/${OVERLAY}"

echo
echo "Done. Check status with:"
echo "  oc get pods -n ${KC_NS}"
echo "  oc get keycloak -n ${KC_NS}"
echo "  oc get postgrescluster -n ${KC_NS}"
