#!/bin/bash

NAMESPACE="$1"
TLS_SECRET_NAME="$NAMESPACE"-tls-secret
HOSTNAME=$2
INSTANCEPATH="./instance/"$HOSTNAME
KEY_FILE="${INSTANCEPATH}/${NAMESPACE}CA.key"
CERT_FILE="${INSTANCEPATH}/${NAMESPACE}CA.crt"
DAYS_VALID=365

CERT_SUBJECT="/C=CA/ST=Ontario/O=DND/OU=TDL/CN=${HOSTNAME}"

echo "🔍 Extracted subject: $CERT_SUBJECT"

echo " Creating output folder "$INSTANCEPATH
mkdir -p $INSTANCEPATH

echo "🔐 Generating new self-signed certificate with subject..."
openssl req -x509 -nodes -days "$DAYS_VALID" -newkey rsa:2048 \
-keyout "$KEY_FILE" -out "$CERT_FILE" -subj "$CERT_SUBJECT" -addext "subjectAltName=DNS:$HOSTNAME"

if [[ $? -eq 0 ]]; then
  echo "✅ Certificate: $CERT_FILE"
  echo "✅ Private Key: $KEY_FILE"
echo "🗝️ Storing Secret: $TLS_SECRET_NAME"
oc delete secret "$TLS_SECRET_NAME" -n "$NAMESPACE" --ignore-not-found
oc create secret tls "$TLS_SECRET_NAME" --cert="$CERT_FILE" --key="$KEY_FILE" --namespace="$NAMESPACE"

else
  echo "❌ Certificate generation failed."
fi




