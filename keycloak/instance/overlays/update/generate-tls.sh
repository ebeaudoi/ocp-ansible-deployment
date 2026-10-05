#!/usr/bin/env bash
# Generate self-signed TLS material for secretGenerator (tls.crt / tls.key).
# Keep HOSTNAME in sync with keycloak-patch.yaml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME="${1:-keycloak.apps.ebdn-rd3.ebeaudoi.tamlab.rdu2.redhat.com}"
DAYS_VALID="${DAYS_VALID:-365}"
CERT_SUBJECT="/C=CA/ST=Ontario/O=DND/OU=TDL/CN=${HOSTNAME}"

openssl req -x509 -nodes -days "${DAYS_VALID}" -newkey rsa:2048 \
  -keyout "${SCRIPT_DIR}/tls.key" \
  -out "${SCRIPT_DIR}/tls.crt" \
  -subj "${CERT_SUBJECT}" \
  -addext "subjectAltName=DNS:${HOSTNAME}"

chmod 600 "${SCRIPT_DIR}/tls.key"
echo "Wrote ${SCRIPT_DIR}/tls.crt and ${SCRIPT_DIR}/tls.key for ${HOSTNAME}"
