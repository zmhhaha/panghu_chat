ARG NODE_IMAGE=arm64v8/node:22-bookworm-slim
FROM ${NODE_IMAGE}

ARG NPM_REGISTRY=https://registry.npmmirror.com
# Exact published official DSH version, e.g. @deepseek-ai/dsh@0.1.6-alpha.2
ARG DSH_PACKAGE
# The official SSH remote provider family. Published only on the 0.1.6 line and
# peer-locked to it, so this must track DSH_PACKAGE. dsh 0.1.5-rc.2 has no
# matching release, which is why the upgrade is mandatory rather than optional.
ARG DSH_SSH_VERSION=0.1.6-alpha.2

ENV NPM_CONFIG_REGISTRY=${NPM_REGISTRY} \
    NODE_ENV=production

# Verify the package before installing OS dependencies. A source-tree version
# is not necessarily published to npm, and mirrors can lag behind npmjs.org.
RUN node -e 'if (!/^@deepseek-ai\/dsh@[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$/.test(process.argv[1])) { console.error("Pin the official @deepseek-ai/dsh package to an exact published version"); process.exit(1); }' "${DSH_PACKAGE}" \
    && npm view "${DSH_PACKAGE}" version

RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i 's|deb.debian.org|mirrors.ustc.edu.cn|g' /etc/apt/sources.list.d/debian.sources; \
    else \
        sed -i 's|deb.debian.org|mirrors.ustc.edu.cn|g' /etc/apt/sources.list; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends git ca-certificates openssh-client; \
    rm -rf /var/lib/apt/lists/*

RUN npm install -g --no-fund --no-audit "${DSH_PACKAGE}"

# `dsh plugin` forwards to pnpm inside the profile directory; that is the
# documented way to install profile dependencies, so pnpm has to exist.
RUN npm install -g --no-fund --no-audit pnpm@10

# Bundle the SSH providers as tarballs instead of installing them into the
# global tree. The profile is composed at first boot from these local files, so
# a boot never downloads anything and the approved set cannot drift. No shell
# variables here on purpose: Docker substitutes ${name} in RUN, and an unknown
# name would expand to nothing.
RUN set -eux; \
    mkdir -p /opt/dsh-ssh-deps; \
    cd /opt/dsh-ssh-deps; \
    npm pack "@deepseek-ai/dsh-ssh@${DSH_SSH_VERSION}" > /dev/null; \
    npm pack "@deepseek-ai/dsh-fs-ssh@${DSH_SSH_VERSION}" > /dev/null; \
    npm pack "@deepseek-ai/dsh-subprocess-ssh@${DSH_SSH_VERSION}" > /dev/null; \
    npm pack "@deepseek-ai/dsh-sandbox-ssh@${DSH_SSH_VERSION}" > /dev/null; \
    mv "deepseek-ai-dsh-ssh-${DSH_SSH_VERSION}.tgz" dsh-ssh.tgz; \
    mv "deepseek-ai-dsh-fs-ssh-${DSH_SSH_VERSION}.tgz" dsh-fs-ssh.tgz; \
    mv "deepseek-ai-dsh-subprocess-ssh-${DSH_SSH_VERSION}.tgz" dsh-subprocess-ssh.tgz; \
    mv "deepseek-ai-dsh-sandbox-ssh-${DSH_SSH_VERSION}.tgz" dsh-sandbox-ssh.tgz; \
    ls -l /opt/dsh-ssh-deps

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin dsh

# ENTRYPOINT, not CMD: the Deployment supplies the subcommand and flags as
# `args`, which replace CMD. Without this the container would try to exec
# "web" as a binary.
COPY auth /opt/dsh-auth
# The profile patch that redirects execution to the SSH remote. Composition is
# config, not code: dsh-base documents that a profile's cordis.patch.yml
# addresses rows by id, which is the supported extension point.
COPY config/cordis.patch.yml /opt/dsh-config/cordis.patch.yml
ENTRYPOINT ["node", "/opt/dsh-auth/supervisor.mjs"]
CMD ["--help"]

USER 10001
WORKDIR /opt/data
