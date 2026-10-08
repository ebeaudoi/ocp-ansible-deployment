#!/usr/bin/env bash
# Compatibility wrapper — Keycloak overlay configuration moved to the repo root.
# Prefer:
#   ./configure-keycloak-overlays.sh
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/configure-keycloak-overlays.sh" "$@"
