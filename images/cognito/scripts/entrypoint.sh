#!/bin/sh
set -eu

config_dir=/app/.cognito
issuer_domain="${COGNITO_ISSUER_DOMAIN:-http://localhost:9229}"

mkdir -p "${config_dir}/db"

# Rendered on every start so COGNITO_ISSUER_DOMAIN stays the single source of
# truth. The issuer is baked into every token as "<domain>/<userPoolId>" and
# must match COGNITO_ISSUER on the sync server exactly, or verify-jwt rejects
# the token with "iss not found".
cat > "${config_dir}/config.json" <<JSON
{
  "TokenConfig": {
    "IssuerDomain": "${issuer_domain}"
  },
  "UserPoolDefaults": {
    "UsernameAttributes": ["email"]
  }
}
JSON

exec node /app/start.js
