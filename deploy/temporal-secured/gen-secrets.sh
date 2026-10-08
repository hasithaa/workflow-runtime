#!/usr/bin/env bash
# Generates the local secrets for the secured setup: the runtime's token-signing key and JWKS, and a CA plus
# frontend certificate for Temporal. Never commit the outputs.
set -euo pipefail
cd "$(dirname "$0")"
SECRETS=../../runtime-api/secrets
mkdir -p "$SECRETS" certs

openssl genrsa -out "$SECRETS/token-signing.key" 2048 2>/dev/null
MOD=$(openssl rsa -in "$SECRETS/token-signing.key" -modulus -noout | cut -d= -f2)
python3 -I - "$MOD" "$SECRETS/jwks.json" <<'PY'
import base64, json, sys
n = base64.urlsafe_b64encode(bytes.fromhex(sys.argv[1])).rstrip(b"=").decode()
json.dump({"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256", "kid": "runtime-1", "n": n, "e": "AQAB"}]},
          open(sys.argv[2], "w"))
PY

openssl req -x509 -newkey rsa:2048 -nodes -keyout certs/ca.key -out certs/ca.pem -days 365 \
  -subj "/CN=Workflow Runtime Local CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout certs/frontend.key -out certs/frontend.csr -subj "/CN=localhost" 2>/dev/null
printf "subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n" > certs/ext.cnf
openssl x509 -req -in certs/frontend.csr -CA certs/ca.pem -CAkey certs/ca.key -CAcreateserial \
  -out certs/frontend.pem -days 365 -extfile certs/ext.cnf 2>/dev/null
rm -f certs/frontend.csr certs/ext.cnf certs/ca.srl
echo "Wrote $SECRETS/{token-signing.key,jwks.json} and certs/{ca.pem,ca.key,frontend.pem,frontend.key}"
