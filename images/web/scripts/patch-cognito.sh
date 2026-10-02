#!/usr/bin/env bash
set -euo pipefail

# Repoints the Logseq web client at a self-hosted Cognito emulator.
#
# The pool id, client id, IdP endpoint and OAuth domain are compile-time `def`s
# in upstream (not goog-defines), and there is no runtime override: config.edn
# is validated against a fixed malli schema that has no auth keys, and the
# :auth/oauth-* app-state keys are unconditionally overwritten from these
# constants on every sync start. Patching the source before the cljs release is
# therefore the only way in.
#
# Run from the Logseq source root. No-op when SELFHOST_COGNITO_ENDPOINT is unset.

ENDPOINT="${SELFHOST_COGNITO_ENDPOINT:-}"
USER_POOL_ID="${SELFHOST_COGNITO_USER_POOL_ID:-}"
CLIENT_ID="${SELFHOST_COGNITO_CLIENT_ID:-}"
OAUTH_DOMAIN="${SELFHOST_COGNITO_OAUTH_DOMAIN:-}"

if [ -z "${ENDPOINT}" ]; then
  echo "patch-cognito: SELFHOST_COGNITO_ENDPOINT unset, building against upstream Logseq Cognito"
  exit 0
fi

for var in USER_POOL_ID CLIENT_ID OAUTH_DOMAIN; do
  if [ -z "${!var}" ]; then
    echo "patch-cognito: SELFHOST_COGNITO_ENDPOINT is set but SELFHOST_COGNITO_${var} is not" >&2
    exit 1
  fi
done

ENDPOINT="${ENDPOINT%/}"

config_cljs=src/main/frontend/config.cljs
cognito_cljs=deps/common/src/logseq/common/cognito_config.cljs
login_cljs=src/main/frontend/components/user/login.cljs

# Every substitution is asserted, so an upstream rename fails the build loudly
# instead of silently shipping an image that still points at AWS.
replace() {
  local file="$1" from="$2" to="$3"
  if ! grep -qF -- "${from}" "${file}"; then
    echo "patch-cognito: expected to find in ${file}: ${from}" >&2
    exit 1
  fi
  python3 - "${file}" "${from}" "${to}" <<'PY'
import pathlib, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
p.write_text(p.read_text().replace(old, new))
PY
}

# 1. Client id, shared by the frontend and the CLI-safe namespace.
replace "${cognito_cljs}" '"69cs1lgme7p8kbgld8n5kseii6"' "\"${CLIENT_ID}\""

# 2. OAuth domain. handler/user.cljs and worker/sync/auth.cljs build the token
#    refresh URL as "https://<domain>/oauth2/token" with the scheme hardcoded,
#    so the emulator has to be reachable over HTTPS on this hostname.
replace "${cognito_cljs}" '"logseq-prod.auth.us-east-1.amazoncognito.com"' "\"${OAUTH_DOMAIN}\""

# 3. IdP endpoint used by handler/user.cljs for direct Cognito calls.
replace "${config_cljs}" '"https://cognito-idp.us-east-1.amazonaws.com/"' "\"${ENDPOINT}/\""

# 4. User pool id. Amplify derives its "region" from the prefix before the
#    underscore; cognito-local pool ids look like local_AbC12345, which parses
#    fine and is only used for endpoint resolution that we override below.
replace "${config_cljs}" '"us-east-1_dtagLnju8"' "\"${USER_POOL_ID}\""
replace "${config_cljs}" '(def REGION "us-east-1")' "(def REGION \"${USER_POOL_ID%%_*}\")"

# 5. Point Amplify at the emulator and drop the identity pool. cognito-local
#    emulates cognito-idp only, not Cognito Identity, and Logseq never uses the
#    identity-pool credentials -- leaving it configured makes fetchAuthSession
#    try to exchange the token for AWS credentials and fail.
replace "${login_cljs}" \
  ':identityPoolId config/IDENTITY-POOL-ID' \
  ":userPoolEndpoint \"${ENDPOINT}\""

# 6. cognito-local implements USER_PASSWORD_AUTH and REFRESH_TOKEN_AUTH only.
#    Amplify defaults to SRP, which the emulator answers with an "Unsupported"
#    500, surfacing in the UI as a generic auth error.
replace "${login_cljs}" \
  '(bean/->js {:username username :password password})' \
  '(bean/->js {:username username :password password :options {:authFlowType "USER_PASSWORD_AUTH"}})'

echo "patch-cognito: repointed web client at ${ENDPOINT} (pool ${USER_POOL_ID})"
