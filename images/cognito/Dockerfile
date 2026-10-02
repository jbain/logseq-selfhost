# syntax=docker/dockerfile:1.26@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
FROM node:24-bookworm-slim@sha256:ba849c60be29959425b8734d57b8b4b7d56f98edd9504c9af091d5281095a71e AS build
ARG COGNITO_LOCAL_REF=v5.3.0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git init . \
  && git remote add origin https://github.com/jagregory/cognito-local.git \
  && git fetch --depth 1 origin "${COGNITO_LOCAL_REF}" \
  && git checkout --detach FETCH_HEAD

# Replace the signing keypair that upstream commits to its own repository.
# esbuild inlines these JSON files into the bundle, so this substitution has to
# happen before the bundle step -- the keys cannot be swapped at runtime.
# Generate them first with images/cognito/scripts/gen-keys.sh.
COPY images/cognito/keys/cognitoLocal.private.json /src/src/keys/cognitoLocal.private.json
COPY images/cognito/keys/cognitoLocal.public.json /src/src/keys/cognitoLocal.public.json

# tokenGenerator.ts signs with keyid "CognitoLocal"; the served JWKS entry must
# carry the same kid or every token fails verification with a "kid" error.
RUN grep -q '"kid": "CognitoLocal"' /src/src/keys/cognitoLocal.public.json \
  && grep -q 'BEGIN RSA PRIVATE KEY' /src/src/keys/cognitoLocal.private.json

RUN corepack enable
RUN --mount=type=cache,target=/usr/local/share/.cache/yarn yarn install --frozen-lockfile
RUN yarn esbuild src/bin/start.ts --outdir=lib --platform=node --target=node22 --bundle

FROM node:24-bookworm-slim@sha256:ba849c60be29959425b8734d57b8b4b7d56f98edd9504c9af091d5281095a71e
LABEL org.opencontainers.image.description="Cognito emulator (cognito-local) for self-hosted Logseq sync auth"

WORKDIR /app
COPY --chown=node:node --from=build /src/lib /app
RUN mkdir -p /app/.cognito/db && chown -R node:node /app/.cognito
COPY --chmod=755 --chown=node:node images/cognito/scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

ENV HOST=0.0.0.0
ENV PORT=9229
ENV COGNITO_ISSUER_DOMAIN=http://localhost:9229

USER node:node
EXPOSE 9229
VOLUME /app/.cognito

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
