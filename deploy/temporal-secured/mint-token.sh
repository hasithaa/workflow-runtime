#!/usr/bin/env bash
# Signs a Temporal access token with the runtime's key, without the runtime running (bootstrap).
# Usage: ./mint-token.sh <permission>... [-- lifetime-seconds]   e.g. ./mint-token.sh temporal-system:admin
set -euo pipefail
cd "$(dirname "$0")"
KEY=../../runtime-api/secrets/token-signing.key
LIFETIME=31536000
PERMS=()
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then LIFETIME=$2; break; fi
  PERMS+=("$1"); shift
done
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
NOW=$(date +%s)
PERMS_JSON=$(printf '"%s",' "${PERMS[@]}"); PERMS_JSON="[${PERMS_JSON%,}]"
HEADER=$(printf '{"alg":"RS256","typ":"JWT","kid":"runtime-1"}' | b64)
PAYLOAD=$(printf '{"iss":"workflow-runtime","sub":"workflow-runtime","iat":%s,"exp":%s,"permissions":%s}' \
  "$NOW" "$((NOW + LIFETIME))" "$PERMS_JSON" | b64)
SIG=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | openssl dgst -sha256 -sign "$KEY" | b64)
echo "$HEADER.$PAYLOAD.$SIG"
