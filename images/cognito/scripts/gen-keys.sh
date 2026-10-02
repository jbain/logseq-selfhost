#!/usr/bin/env bash
set -euo pipefail

# Generates the RSA keypair that cognito-local uses to sign JWTs.
#
# Upstream cognito-local ships a keypair committed to its public repository,
# which means anyone can mint tokens your sync server will accept. This script
# produces a keypair that only you hold. Run it once; keep the output. The
# directory is gitignored.
#
# Rotating the keypair invalidates every issued token and forces a re-login.
# The sync server caches JWKS for 6 hours, so expect up to 6 hours of rejected
# tokens after a rotation unless you restart it.

KEY_DIR="${KEY_DIR:-$(cd "$(dirname "$0")/.." && pwd)/keys}"
NODE_IMAGE="${NODE_IMAGE:-node:24-bookworm-slim@sha256:ba849c60be29959425b8734d57b8b4b7d56f98edd9504c9af091d5281095a71e}"
FORCE="${FORCE:-}"

# Override with CONTAINER_ENGINE=docker|podman if both are installed.
ENGINE="${CONTAINER_ENGINE:-}"
if [ -z "${ENGINE}" ]; then
  if command -v podman >/dev/null 2>&1; then
    ENGINE=podman
  elif command -v docker >/dev/null 2>&1; then
    ENGINE=docker
  else
    echo "neither podman nor docker found on PATH" >&2
    exit 1
  fi
fi

if [ -f "${KEY_DIR}/cognitoLocal.private.json" ] && [ -z "${FORCE}" ]; then
  echo "keys already exist at ${KEY_DIR}" >&2
  echo "re-run with FORCE=1 to overwrite (this invalidates all issued tokens)" >&2
  exit 1
fi

mkdir -p "${KEY_DIR}"

generator=$(cat <<'JS'
const { generateKeyPairSync } = require("node:crypto");
const { writeFileSync } = require("node:fs");

const { privateKey, publicKey } = generateKeyPairSync("rsa", {
  modulusLength: 2048,
});

// jsonwebtoken signs with the PEM; the server publishes the JWK. kid must be
// "CognitoLocal" to match the hardcoded keyid in tokenGenerator.ts.
const meta = { use: "sig", kid: "CognitoLocal", alg: "RS256" };
const privJwk = privateKey.export({ format: "jwk" });
const pubJwk = publicKey.export({ format: "jwk" });

writeFileSync(
  "/out/cognitoLocal.private.json",
  JSON.stringify(
    {
      jwk: { ...privJwk, ...meta },
      pem: privateKey.export({ type: "pkcs1", format: "pem" }),
    },
    null,
    2,
  ),
);

writeFileSync(
  "/out/cognitoLocal.public.json",
  JSON.stringify(
    {
      jwk: { kty: pubJwk.kty, e: pubJwk.e, ...meta, n: pubJwk.n },
      pem: publicKey.export({ type: "pkcs1", format: "pem" }),
    },
    null,
    2,
  ),
);
JS
)

mount_spec="${KEY_DIR}:/out"
user_args=()

case "${ENGINE}" in
  podman)
    # Rootless podman already maps the container's root to the invoking user, so
    # the output lands owned by you. Forcing --user to a non-zero UID would map
    # it into a subuid instead, leaving keys you cannot read or chmod.
    # :Z relabels for SELinux (a no-op where SELinux is not enforcing) and is
    # required for the container to write into the mount on Fedora/RHEL.
    mount_spec="${mount_spec}:Z"
    ;;
  *)
    # Docker runs the container as real root, which would leave root-owned keys.
    user_args=(--user "$(id -u):$(id -g)")
    ;;
esac

"${ENGINE}" run --rm \
  "${user_args[@]}" \
  --volume "${mount_spec}" \
  "${NODE_IMAGE}" \
  node -e "${generator}"

if [ ! -r "${KEY_DIR}/cognitoLocal.private.json" ]; then
  echo "key was written but is not readable by $(id -un)." >&2
  echo "This happens with rootful podman or docker-as-root; fix with:" >&2
  echo "  sudo chown $(id -u):$(id -g) ${KEY_DIR}/cognitoLocal.*.json" >&2
  exit 1
fi

chmod 600 "${KEY_DIR}/cognitoLocal.private.json"

echo "wrote ${KEY_DIR}/cognitoLocal.private.json"
echo "wrote ${KEY_DIR}/cognitoLocal.public.json"
echo
echo "Back these up. Losing them forces every client to log in again."
