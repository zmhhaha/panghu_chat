ARG NODE_IMAGE=arm64v8/node:22-bookworm-slim
FROM ${NODE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

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
        openssh-client \
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

RUN useradd --uid 10000 --create-home --shell /bin/bash --home-dir /workspace dev \
    && install -d -o 10000 -g 10000 /workspace

# TODO(stage 2): the project transport listener is NOT part of this image yet.
# The change design prefers the official SSH provider family; if that proves
# usable, add a non-root sshd on port 2222 here and configure it from a
# project-scoped credential held only by the web service. If a custom provider
# is needed instead, add that listener here. Until then the container stays up
# with nothing listening, the Service port refuses connections, and NetworkPolicy
# already restricts who may try.
ENTRYPOINT ["/bin/sleep", "infinity"]

USER 10000
WORKDIR /workspace
