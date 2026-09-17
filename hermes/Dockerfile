ARG HERMES_IMAGE
FROM ${HERMES_IMAGE}
USER root
ARG PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
ARG NPM_REGISTRY=https://registry.npmmirror.com
# Keep runtime package installation on the same selected mirrors.
ENV PIP_INDEX_URL=${PIP_INDEX_URL} UV_DEFAULT_INDEX=${PIP_INDEX_URL} NPM_CONFIG_REGISTRY=${NPM_REGISTRY}
COPY requirements.txt /opt/intelligence/requirements.txt
RUN if /opt/hermes/.venv/bin/python -m pip --version >/dev/null 2>&1; then \
      /opt/hermes/.venv/bin/python -m pip install --index-url "$PIP_INDEX_URL" --timeout 60 --retries 3 --no-cache-dir -r /opt/intelligence/requirements.txt; \
    else \
      uv pip install --index-url "$PIP_INDEX_URL" --python /opt/hermes/.venv/bin/python -r /opt/intelligence/requirements.txt; \
    fi
COPY app /opt/intelligence/app
COPY config /opt/intelligence/config
COPY web-overlay /opt/intelligence/web-overlay
COPY scripts/apply-web-overlay.py /opt/intelligence/scripts/apply-web-overlay.py
RUN /opt/hermes/.venv/bin/python /opt/intelligence/scripts/apply-web-overlay.py
# The dashboard serves the compiled bundle, not web/src directly.
RUN cd /opt/hermes && npm run build --workspace web
ENV PYTHONPATH=/opt/intelligence PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
# Preserve upstream's s6 entrypoint for the dashboard. Jobs override command.
