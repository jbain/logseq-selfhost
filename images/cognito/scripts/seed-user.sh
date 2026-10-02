#!/usr/bin/env bash
set -euo pipefail

# Creates a user pool, an app client, and a confirmed user in cognito-local,
# then prints the values to paste into the sync and web configuration.
#
# cognito-local does not verify request signatures, so these are plain HTTP
# calls against the Cognito JSON protocol -- no aws-cli or credentials needed.
#
# Usage:
#   EMAIL=me@example.com PASSWORD='...' ./images/cognito/scripts/seed-user.sh
#
# Environment:
#   COGNITO_URL     cognito-local base URL          (default http://127.0.0.1:9229)
#   ISSUER_DOMAIN   public issuer origin            (default $COGNITO_URL)
#   EMAIL           user's email address            (required)
#   PASSWORD        user's password                 (required)
#   WEB_ORIGIN      web app origin for CallbackURLs (default https://logseq.example.com)
#   POOL_NAME       user pool name                  (default logseq-selfhost)
#   CLIENT_NAME     app client name                 (default logseq-web)
#   USER_POOL_ID    reuse an existing pool instead of creating one

COGNITO_URL="${COGNITO_URL:-http://127.0.0.1:9229}"
ISSUER_DOMAIN="${ISSUER_DOMAIN:-${COGNITO_URL}}"
EMAIL="${EMAIL:-}"
PASSWORD="${PASSWORD:-}"
WEB_ORIGIN="${WEB_ORIGIN:-https://logseq.example.com}"
POOL_NAME="${POOL_NAME:-logseq-selfhost}"
CLIENT_NAME="${CLIENT_NAME:-logseq-web}"
USER_POOL_ID="${USER_POOL_ID:-}"

if [ -z "${EMAIL}" ] || [ -z "${PASSWORD}" ]; then
  echo "EMAIL and PASSWORD are required" >&2
  exit 1
fi

case "${EMAIL}" in
  *@*) ;;
  *)
    # The pool uses UsernameAttributes=["email"], and AdminCreateUser rejects a
    # username that is not an email address in that mode.
    echo "EMAIL must be an email address" >&2
    exit 1
    ;;
esac

# Logseq's login form enforces this client-side before it ever calls Cognito.
if ! printf '%s' "${PASSWORD}" | grep -Eq '^.{8,}$' \
  || ! printf '%s' "${PASSWORD}" | grep -q '[a-z]' \
  || ! printf '%s' "${PASSWORD}" | grep -q '[A-Z]' \
  || ! printf '%s' "${PASSWORD}" | grep -q '[]!@#$%^&*()_+=[{};'"'"':"\\|,.<>/?~`-]'; then
  echo "PASSWORD must be 8+ chars with a lowercase, an uppercase, and a symbol" >&2
  echo "(Logseq's login form rejects anything weaker before it reaches Cognito)" >&2
  exit 1
fi

json_get() {
  # $1 = dotted path, reads JSON on stdin
  python3 -c '
import json, sys
doc = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    doc = doc[part]
print(doc)
' "$1"
}

call() {
  # $1 = Cognito API target, $2 = JSON body
  local target="$1" body="$2" response status
  response="$(
    curl --noproxy '*' -sS \
      -o /tmp/cognito-seed-body.$$ \
      -w '%{http_code}' \
      -X POST "${COGNITO_URL}/" \
      -H "x-amz-target: AWSCognitoIdentityProviderService.${target}" \
      -H 'content-type: application/x-amz-json-1.1' \
      --data "${body}"
  )"
  status="${response}"
  body="$(cat /tmp/cognito-seed-body.$$)"
  rm -f /tmp/cognito-seed-body.$$
  if [ "${status}" != "200" ]; then
    echo "${target} failed with HTTP ${status}:" >&2
    echo "${body}" >&2
    exit 1
  fi
  printf '%s' "${body}"
}

if [ -z "${USER_POOL_ID}" ]; then
  USER_POOL_ID="$(
    call CreateUserPool "$(
      python3 -c '
import json, sys
print(json.dumps({
    "PoolName": sys.argv[1],
    "UsernameAttributes": ["email"],
    "AutoVerifiedAttributes": ["email"],
}))
' "${POOL_NAME}"
    )" | json_get UserPool.Id
  )"
  echo "created user pool ${USER_POOL_ID}"
else
  echo "reusing user pool ${USER_POOL_ID}"
fi

CLIENT_ID="$(
  call CreateUserPoolClient "$(
    python3 -c '
import json, sys
pool_id, client_name, web_origin = sys.argv[1:4]
print(json.dumps({
    "UserPoolId": pool_id,
    "ClientName": client_name,
    # cognito-local only implements USER_PASSWORD_AUTH and REFRESH_TOKEN_AUTH.
    # Logseq is patched to request USER_PASSWORD_AUTH instead of the SRP
    # default, which cognito-local does not support.
    "ExplicitAuthFlows": ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"],
    "CallbackURLs": [web_origin.rstrip("/") + "/"],
    "IdTokenValidity": 24,
    "AccessTokenValidity": 24,
    "RefreshTokenValidity": 30,
    "TokenValidityUnits": {
        "IdToken": "hours",
        "AccessToken": "hours",
        "RefreshToken": "days",
    },
}))
' "${USER_POOL_ID}" "${CLIENT_NAME}" "${WEB_ORIGIN}"
  )" | json_get UserPoolClient.ClientId
)"
echo "created app client ${CLIENT_ID}"

call AdminCreateUser "$(
  python3 -c '
import json, sys
pool_id, email, password = sys.argv[1:4]
print(json.dumps({
    "UserPoolId": pool_id,
    "Username": email,
    "UserAttributes": [
        {"Name": "email", "Value": email},
        {"Name": "email_verified", "Value": "true"},
    ],
    "TemporaryPassword": password,
    "MessageAction": "SUPPRESS",
}))
' "${USER_POOL_ID}" "${EMAIL}" "${PASSWORD}"
)" > /dev/null
echo "created user ${EMAIL}"

# Permanent=true also flips UserStatus to CONFIRMED, so AdminConfirmSignUp is
# neither needed nor allowed afterwards (it rejects non-UNCONFIRMED users).
call AdminSetUserPassword "$(
  python3 -c '
import json, sys
pool_id, email, password = sys.argv[1:4]
print(json.dumps({
    "UserPoolId": pool_id,
    "Username": email,
    "Password": password,
    "Permanent": True,
}))
' "${USER_POOL_ID}" "${EMAIL}" "${PASSWORD}"
)" > /dev/null
echo "confirmed user ${EMAIL}"

issuer="${ISSUER_DOMAIN%/}/${USER_POOL_ID}"

cat <<OUT

Done. Configuration values:

  images/sync/.env
    COGNITO_ISSUER=${issuer}
    COGNITO_CLIENT_ID=${CLIENT_ID}
    COGNITO_JWKS_URL=${issuer}/.well-known/jwks.json

    On a shared container network, keep COGNITO_ISSUER as printed but fetch JWKS
    internally instead, avoiding a round trip through your reverse proxy:
    COGNITO_JWKS_URL=http://cognito:9229/${USER_POOL_ID}/.well-known/jwks.json

  images/web build args
    SELFHOST_COGNITO_ENDPOINT=${ISSUER_DOMAIN%/}
    SELFHOST_COGNITO_USER_POOL_ID=${USER_POOL_ID}
    SELFHOST_COGNITO_CLIENT_ID=${CLIENT_ID}
    SELFHOST_COGNITO_OAUTH_DOMAIN=$(printf '%s' "${ISSUER_DOMAIN%/}" | sed -e 's|^https\{0,1\}://||')

OUT
