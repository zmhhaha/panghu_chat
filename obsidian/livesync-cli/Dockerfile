# syntax=docker/dockerfile:1
#
# Self-hosted LiveSync CLI, built for ARM64.
#
# Upstream publishes no container image: src/apps/cli/Dockerfile in
# vrtmrz/obsidian-livesync is documented as a local build only. This file
# mirrors that build's three stages (builder, runtime-deps, runtime) with three
# changes the platform needs:
#
#   - the Node base image is a build argument, so it can be pinned to a digest
#     instead of following a floating tag;
#   - the npm registry is a build argument, so the install does not depend on
#     reaching registry.npmjs.org from the cluster;
#   - the Debian mirror is rewritten, because deb.debian.org is slow enough
#     from this network to stall the build (observed: the upstream Dockerfile
#     stopped making progress on a 2.6 MB package).
#
# The Debian rewrite follows the existing convention in panghu_chat/dsh/Dockerfile.
#
# The build context is a checkout of vrtmrz/obsidian-livesync at the commit
# named by LIVESYNC_REF; build.sh prepares it.
#
# python3/make/g++ are not optional: leveldown is a native addon and is
# compiled during the install. The runtime stage does not carry them.

ARG NODE_IMAGE=arm64v8/node:22-bookworm-slim
ARG NPM_REGISTRY=https://registry.npmmirror.com
ARG DEBIAN_MIRROR=mirrors.ustc.edu.cn

# ── Stage 1: build the CLI bundle ────────────────────────────────────────────
FROM ${NODE_IMAGE} AS builder
ARG NPM_REGISTRY
ARG DEBIAN_MIRROR
RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
    else \
        sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends python3 make g++; \
    rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY package.json package-lock.json ./
RUN npm config set registry "${NPM_REGISTRY}" && npm install
COPY . .
RUN cd src/apps/cli && npm run build

# ── Stage 2: resolve the runtime dependency tree ─────────────────────────────
# Native addons are compiled here, against the same base image the runtime
# stage uses. devDependencies are removed before resolving so the tree matches
# what actually ships.
FROM ${NODE_IMAGE} AS runtime-deps
ARG NPM_REGISTRY
ARG DEBIAN_MIRROR
RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
    else \
        sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends python3 make g++; \
    rm -rf /var/lib/apt/lists/*
WORKDIR /deps
COPY src/apps/cli/package.json ./package.json
RUN npm config set registry "${NPM_REGISTRY}" \
    && npm pkg delete devDependencies \
    && npm install --omit=dev

# ── Stage 3: runtime ─────────────────────────────────────────────────────────
FROM ${NODE_IMAGE}
WORKDIR /app
COPY --from=runtime-deps /deps/node_modules ./node_modules
COPY --from=builder /build/src/apps/cli/dist ./dist
# Upstream writes this as `COPY --chmod=755`, which requires BuildKit. The
# cluster's docker daemon builds with the legacy builder, so the mode is set
# with a separate RUN instead of depending on the builder flavour.
COPY src/apps/cli/docker-entrypoint.sh /usr/local/bin/livesync-cli
RUN chmod 755 /usr/local/bin/livesync-cli
VOLUME ["/data"]
ENTRYPOINT ["livesync-cli"]
