# Cognito Emulator (cognito-local)

[![License](https://img.shields.io/github/license/yshalsager/logseq-selfhost.svg)](https://github.com/yshalsager/logseq-selfhost/blob/master/LICENSE)

This image runs [cognito-local](https://github.com/jagregory/cognito-local) so
that self-hosted Logseq sync can issue and validate its own JWTs instead of
depending on AWS Cognito.

Unlike the other images in this repository, **this one is built locally and
never published**: it embeds a private signing key that must not leave your
machine.

## How auth works

Logseq's sync protocol is JWT bearer auth. Nothing in it is AWS-specific:

1. The client signs in against Cognito and receives an **id token**, an access
   token, and a refresh token.
2. The client sends `authorization: Bearer <id-token>` on every sync request
   (`deps/db-sync`, `worker/auth.cljs`).
3. The sync server validates the token in `logseq.common.authorization/verify-jwt`
   entirely from environment variables — it checks `iss` against
   `COGNITO_ISSUER`, `aud`/`client_id` against `COGNITO_CLIENT_ID` (plus the
   comma-separated `COGNITO_CLIENT_IDS`), the `exp` claim, then the RS256
   signature against the JWKS fetched from `COGNITO_JWKS_URL` (cached 6 hours).
4. The user identity is the token's `sub` claim.
5. When the id token nears expiry the client POSTs `grant_type=refresh_token` to
   `https://<OAUTH-DOMAIN>/oauth2/token`. cognito-local implements that endpoint
   as of v5.3.0.

So the server side needs **no code changes at all** — only the three
`COGNITO_*` variables. The client side is the hard part, see below.

## What has to be patched, and why

The pool id, client id, IdP endpoint, and OAuth domain are compile-time `def`s
in `src/main/frontend/config.cljs` and
`deps/common/src/logseq/common/cognito_config.cljs`. They are **not**
`goog-define`s, and there is no runtime escape hatch:

- `config.edn` (both graph-level and global) is validated against a fixed malli
  schema in `src/main/frontend/schema/handler/` that contains no auth keys.
- The `:auth/oauth-domain`, `:auth/oauth-client-id`, and `:auth/oauth-token-url`
  app-state keys look like an indirection, but
  `handler/db_based/sync.cljs` and `handler/events/rtc.cljs` unconditionally
  overwrite them from the compile-time constants before every sync start.
- The only user-configurable auth-adjacent value is the sync server URL
  (`localStorage["sync-server-url"]`, exposed in Settings).

`images/web/scripts/patch-cognito.sh` therefore rewrites the constants in the
source tree before the ClojureScript release build. It makes six substitutions,
each of them asserted so that an upstream rename fails the build loudly rather
than silently shipping an image still pointed at AWS:

| # | File | Change |
| --- | --- | --- |
| 1 | `cognito_config.cljs` | client id |
| 2 | `cognito_config.cljs` | OAuth domain (token refresh host) |
| 3 | `config.cljs` | `COGNITO-IDP` endpoint |
| 4 | `config.cljs` | `USER-POOL-ID` and `REGION` |
| 5 | `login.cljs` | `:identityPoolId` → `:userPoolEndpoint` |
| 6 | `login.cljs` | force `authFlowType: "USER_PASSWORD_AUTH"` |

Patch 5 drops the identity pool because cognito-local emulates `cognito-idp`
only, not Cognito Identity; leaving it configured makes `fetchAuthSession` try
to exchange the token for AWS credentials and fail. Patch 6 is required because
Amplify defaults to SRP, which cognito-local does not implement.

## Limitations

**The official *prebuilt* desktop and mobile apps cannot use this.** Their
Cognito constants are compiled into the shipped binary, and `verify-jwt` accepts
exactly one issuer, so there is no way to run the emulator alongside real Logseq
accounts.

Clients you build yourself are fine. `images/web/scripts/patch-cognito.sh`
operates on the source tree, not on a build target, and the files it rewrites
(`config.cljs`, `cognito_config.cljs`, `login.cljs`) are shared by the `app`,
`electron`, and `mobile` cljs builds — so the same patch works for
`release-electron` and `release-mobile` as it does for the web bundle. Run it
against a checkout before the cljs release step.

**Semantic REST and MCP will not authorize.** Those routes in
`images/sync-worker` require `logseq/read` / `logseq/write` scopes, and
cognito-local hardcodes `scope: "aws.cognito.signin.user.admin"` on the access
token. Its `PreTokenGeneration` hook only rewrites the *id* token, so there is
no way to inject the scopes. Plain sync via `images/sync` is unaffected.

**Only `USER_PASSWORD_AUTH` and `REFRESH_TOKEN_AUTH` work.** Password reset,
MFA, and self-service signup are partially implemented at best. Create users
with the seeding script below.

## Setup

Everything below runs from the repository root.

### 1. Generate a signing keypair

Upstream cognito-local commits its signing keypair to its public repository, so
anyone could mint tokens your sync server would accept. This generates one only
you hold:

```bash
./images/cognito/scripts/gen-keys.sh
```

Writes `images/cognito/keys/` (gitignored). Back it up — losing it forces every
client to log in again. esbuild inlines these files into the bundle, which is
why the image has to be built rather than pulled.

### 2. Configure and start the emulator

```bash
cp images/cognito/.env.example images/cognito/.env
```

Set `COGNITO_ISSUER_DOMAIN` to the public HTTPS origin your reverse proxy serves
the emulator on, for example `https://cognito.example.com`. This value is baked
into every token as `<domain>/<userPoolId>`, so it must match `COGNITO_ISSUER`
on the sync server exactly.

```bash
docker compose -f images/cognito/docker-compose.yml up -d --build
```

Point your reverse proxy at the published port (default `9229`). HTTPS is
required: the client builds the refresh URL as `https://<domain>/oauth2/token`
with the scheme hardcoded, and a browser on an HTTPS page will block plain-HTTP
Cognito calls as mixed content.

### 3. Create a user

```bash
EMAIL=you@example.com \
PASSWORD='ChangeMe1!' \
COGNITO_URL=http://127.0.0.1:9229 \
ISSUER_DOMAIN=https://cognito.example.com \
WEB_ORIGIN=https://logseq.example.com \
  ./images/cognito/scripts/seed-user.sh
```

This creates a user pool (`UsernameAttributes=["email"]`), an app client with
the two supported auth flows and 24h/30d token validity, then creates the user
and sets a permanent password — which also marks the account `CONFIRMED`, so no
email confirmation code is involved.

The password must satisfy Logseq's own client-side policy (8+ characters with a
lowercase letter, an uppercase letter, and a symbol); the script rejects weaker
ones up front rather than letting the login form do it later.

It prints the values for the next two steps. To add more users later, pass the
existing `USER_POOL_ID` so a second pool is not created:

```bash
USER_POOL_ID=local_AbC12345 EMAIL=other@example.com PASSWORD='ChangeMe2!' \
  ./images/cognito/scripts/seed-user.sh
```

### 4. Point the sync server at the emulator

In `images/sync/.env`, replace the three Cognito values with the printed ones:

```ini
COGNITO_ISSUER=https://cognito.example.com/local_AbC12345
COGNITO_CLIENT_ID=<app client id>
COGNITO_JWKS_URL=https://cognito.example.com/local_AbC12345/.well-known/jwks.json
```

```bash
docker compose -f images/sync/docker-compose.yml up -d
```

The server caches JWKS for 6 hours, so restart it after any key rotation.

### 5. Build and run the web app

The GHCR web image is compiled against Logseq's Cognito, so it has to be rebuilt
locally. Put the printed build args in `images/web/.env`, then:

```bash
docker compose \
  -f images/web/docker-compose.yml \
  -f images/web/docker-compose.selfhost-auth.yml \
  up -d --build
```

### 6. Log in

Open the web app, sign in with the email and password from step 3, then set the
sync server URL in Settings to your `images/sync` origin.

## Verifying

```bash
# JWKS is served and carries the expected key id
curl -s https://cognito.example.com/local_AbC12345/.well-known/jwks.json

# Sign in and mint tokens directly
curl -s -X POST https://cognito.example.com/ \
  -H 'x-amz-target: AWSCognitoIdentityProviderService.InitiateAuth' \
  -H 'content-type: application/x-amz-json-1.1' \
  -d '{"AuthFlow":"USER_PASSWORD_AUTH","ClientId":"<client-id>",
       "AuthParameters":{"USERNAME":"you@example.com","PASSWORD":"ChangeMe1!"}}'

# Use the returned IdToken against the sync server
curl -s -H 'authorization: Bearer <IdToken>' https://sync.example.com/graphs
```

A `200` with a `{"graphs":[...]}` body means the whole chain works: the emulator
signed the token, the sync server fetched the JWKS, and the signature, issuer,
and audience all checked out.

`images/sync/scripts/smoke-test.sh` also accepts `BEARER_TOKEN`, but its default
`GRAPH_ID` is a placeholder — a token that authenticates fine still gets `403`
on a graph the user does not own. Pass a real `GRAPH_ID` for that check to be
meaningful.

## Podman and systemd

The Containerfile is podman-compatible. The three non-baseline features it uses
are all supported by buildah: `RUN --mount=type=cache` (documented as
`bind, cache, secret and tmpfs`), `COPY --chmod`, and `COPY --chown`. The
`# syntax=` line on line 1 is silently ignored by `podman build` — harmless, but
it means the pinned frontend digest buys you nothing there.

```bash
podman build -f images/cognito/Dockerfile -t logseq-selfhost-cognito:local .
```

`gen-keys.sh` and `seed-user.sh` both work under podman. The key script
auto-detects the engine (override with `CONTAINER_ENGINE=docker|podman`) and
adjusts two things that differ:

- It does **not** pass `--user` under podman. Rootless podman already maps the
  container's root to your host user, so output lands owned by you; forcing a
  non-zero UID would map it into a subuid and leave keys you cannot read.
- It appends `:Z` to the bind mount, which SELinux requires for the container to
  write into it on Fedora/RHEL.

`seed-user.sh` only needs `curl` and `python3` — no engine at all.

### Quadlet units

Unit files for the whole stack live in `images/*/quadlet/`:

```bash
mkdir -p ~/.config/containers/systemd ~/.config/logseq-selfhost
cp quadlet/logseq.network                                   ~/.config/containers/systemd/
cp images/cognito/quadlet/logseq-cognito.{container,volume} ~/.config/containers/systemd/
cp images/sync/quadlet/logseq-sync.{container,volume}       ~/.config/containers/systemd/
cp images/web/quadlet/logseq-web.container                  ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start logseq-cognito logseq-sync logseq-web
```

All three join the shared network defined in `quadlet/logseq.network` (podman
network `systemd-logseq`), each with a short `NetworkAlias` — `cognito`, `sync`,
`web`. You never start the network yourself: referencing a unit as
`Network=logseq.network` makes Quadlet generate the dependency automatically.

The payoff is internal DNS. Point the sync server's JWKS fetch straight at the
emulator and leave the issuer public:

```ini
COGNITO_ISSUER=https://cognito.example.com/local_AbC12345
COGNITO_JWKS_URL=http://cognito:9229/local_AbC12345/.well-known/jwks.json
```

`COGNITO_ISSUER` is only string-compared against the token's `iss` claim, while
`COGNITO_JWKS_URL` is actually fetched — so verification never hairpins out
through your reverse proxy and back. This is the arrangement the end-to-end test
used, with the JWKS served over the container network and the issuer set to the
public HTTPS URL.

### Reverse proxy topology

The units publish ports (9229, 8787, 3001) so a proxy running **on the host** can
reach them. Two adjustments depending on your setup:

- **Proxy on the host:** tighten each to loopback, e.g.
  `PublishPort=127.0.0.1:9229:9229`, so nothing is exposed on the LAN.
- **Proxy in a container:** add `Network=logseq.network` to the proxy unit and
  drop `PublishPort` from these three entirely — it can then reach
  `http://cognito:9229`, `http://sync:8787`, and `http://web:8080` by alias.
  Note the web container listens on **8080** internally, not 3001.

The units read `EnvironmentFile=%h/.config/logseq-selfhost/<name>.env`, so
create `cognito.env` (with `COGNITO_ISSUER_DOMAIN`) and `sync.env` (with the
`COGNITO_*` and `DB_SYNC_*` values). These replace the Compose files — Compose is
still there for local development, but you do not need it under systemd.

Notes for rootless:

- `loginctl enable-linger $USER`, or the units stop when you log out.
- The locally built images use `Image=localhost/...` with `Pull=never` so systemd
  does not try to resolve them against a registry.
- The published ports (9229, 8787, 3001) are all above 1024, so no privileged
  binding is needed.
- The sync unit is only `After=` the emulator, not `Requires=`. The sync server
  fetches JWKS lazily and caches it for 6 hours, so it tolerates the emulator
  restarting underneath it.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `401` on every request | Token expired, or `COGNITO_ISSUER` does not exactly match `<COGNITO_ISSUER_DOMAIN>/<userPoolId>` |
| `500` and `aud not found` in the sync logs | `COGNITO_CLIENT_ID` does not match the `aud` claim. Note this surfaces as a `500`, not a `401` |
| `500` and `kid` in the sync logs | The emulator was rebuilt with a different keypair. Restart the sync server to drop its 6-hour JWKS cache |
| `403` on a sync route while `/graphs` returns `200` | Auth succeeded; the user just has no access to that graph |
| Generic auth error in the login form | Usually the SRP fallback — confirm patch 6 applied and the app client allows `ALLOW_USER_PASSWORD_AUTH` |
| Mixed-content errors in the browser console | The emulator is being reached over HTTP from an HTTPS page |

## Security notes

Even with your own keypair, this is an emulator: it does not enforce developer
credentials on admin operations, and anyone who can reach it can call
`AdminSetUserPassword`. Keep it behind your reverse proxy with the same
protections you would give an admin panel, and prefer restricting it to a VPN or
trusted network.

## Upstream URLs

- [cognito-local](https://github.com/jagregory/cognito-local)
- [OAuth2 authorization code flow support (v5.3.0)](https://github.com/jagregory/cognito-local/pull/471)
