ARG NODE_IMAGE=arm64v8/node:22-bookworm-slim
FROM ${NODE_IMAGE}

ARG NPM_REGISTRY=https://registry.npmmirror.com
# Exact published official DSH version, e.g. @deepseek-ai/dsh@0.1.5-rc.2
ARG DSH_PACKAGE

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
    apt-get install -y --no-install-recommends git ca-certificates; \
    rm -rf /var/lib/apt/lists/*

RUN npm install -g --no-fund --no-audit "${DSH_PACKAGE}"

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin dsh

# ENTRYPOINT, not CMD: the Deployment supplies the subcommand and flags as
# `args`, which replace CMD. Without this the container would try to exec
# "web" as a binary.
COPY auth /opt/dsh-auth
ENTRYPOINT ["node", "/opt/dsh-auth/supervisor.mjs"]
CMD ["--help"]

USER 10001
WORKDIR /opt/data
