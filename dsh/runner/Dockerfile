ARG NODE_IMAGE=arm64v8/node:22-bookworm-slim
FROM ${NODE_IMAGE}

ARG NPM_REGISTRY=https://registry.npmmirror.com
# Must match the DSH release composed in the web image; the SSH family is
# published only on the 0.1.6 line.
ARG DSH_SSH_VERSION=0.1.6-alpha.2

ENV DEBIAN_FRONTEND=noninteractive \
    NPM_CONFIG_REGISTRY=${NPM_REGISTRY}

RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i 's|deb.debian.org|mirrors.ustc.edu.cn|g' /etc/apt/sources.list.d/debian.sources; \
    else \
        sed -i 's|deb.debian.org|mirrors.ustc.edu.cn|g' /etc/apt/sources.list; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        jq \
        less \
        openssh-server \
        pkg-config \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        wget; \
    rm -rf /var/lib/apt/lists/*

# No sudo, and no package manager writes outside the workspace: OS packages
# belong in this image, language dependencies go under $HOME on the PVC.
RUN rm -f /usr/bin/sudo

# The DSH remote helper plus its runtime dependencies. dsh-ssh's README requires
# these to live outside the workspace and outside writable temporary roots --
# /opt/dsh-remote satisfies both, and keeps the agent from editing the code that
# confines it.
RUN npm install --prefix /opt/dsh-remote --no-fund --no-audit --omit=dev \
        "@deepseek-ai/dsh-ssh@${DSH_SSH_VERSION}"

# No bubblewrap on purpose: on this cluster it cannot mount procfs inside the
# container, so shipping it would only let the provider pick a backend that
# cannot work. The official ARM64 platform package the helper depends on still
# carries its Landlock launcher, but the kernel does not implement Landlock
# either. Neither is a startup requirement -- see docs/ssh-remote.md section 10.

# dsh-ssh verifies the installed helper against a digest before it will use the
# connection. Publish the value here so deployment can read it instead of
# hashing by hand and drifting.
RUN set -eux; \
    helper=/opt/dsh-remote/node_modules/@deepseek-ai/dsh-ssh/lib/helper.js; \
    [ -f "$helper" ]; \
    sha256sum "$helper" | cut -d' ' -f1 > /opt/dsh-remote/helper.sha256; \
    cat /opt/dsh-remote/helper.sha256

# Host keys and authorized_keys live on a mounted volume so the host identity is
# stable across restarts; the web side pins it in known_hosts and dsh-ssh
# requires strict host-key checking.
RUN install -d -m 0700 -o 10000 -g 10000 /state

RUN useradd --uid 10000 --create-home --shell /bin/bash --home-dir /workspace dev \
    && install -d -o 10000 -g 10000 /workspace

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/dsh-runner-entrypoint
RUN chmod 0755 /usr/local/bin/dsh-runner-entrypoint

EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/dsh-runner-entrypoint"]

USER 10000
WORKDIR /workspace
