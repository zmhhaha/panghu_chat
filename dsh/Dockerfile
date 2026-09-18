ARG NODE_IMAGE=arm64v8/node:22-bookworm-slim
FROM ${NODE_IMAGE}

ARG NPM_REGISTRY=https://registry.npmmirror.com
# Exact published DSH version, e.g. deepseek-harness@0.1.6-alpha.2
ARG DSH_PACKAGE

ENV NPM_CONFIG_REGISTRY=${NPM_REGISTRY} \
    NODE_ENV=production

RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i 's|deb.debian.org|mirrors.ustc.edu.cn|g' /etc/apt/sources.list.d/debian.sources; \
    else \
        sed -i 's|deb.debian.org|mirrors.ustc.edu.cn|g' /etc/apt/sources.list; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends git ca-certificates; \
    rm -rf /var/lib/apt/lists/*

# Require an exact pinned version -- never :latest and never a range.
RUN case "${DSH_PACKAGE}" in \
        *@[0-9]*) ;; \
        *) echo 'DSH_PACKAGE must pin an exact version, e.g. deepseek-harness@0.1.6-alpha.2' >&2; exit 1 ;; \
    esac

RUN npm install -g --no-fund --no-audit "${DSH_PACKAGE}"

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin dsh

# ENTRYPOINT, not CMD: the Deployment supplies the subcommand and flags as
# `args`, which replace CMD. Without this the container would try to exec
# "web" as a binary.
ENTRYPOINT ["dsh"]
CMD ["--help"]

USER 10001
WORKDIR /opt/data
