ARG HERMES_IMAGE
FROM ${HERMES_IMAGE}
USER root
COPY requirements.txt /opt/intelligence/requirements.txt
RUN /opt/hermes/.venv/bin/python -m pip --version >/dev/null 2>&1 \
    && /opt/hermes/.venv/bin/python -m pip install --no-cache-dir -r /opt/intelligence/requirements.txt \
    || uv pip install --python /opt/hermes/.venv/bin/python -r /opt/intelligence/requirements.txt
COPY app /opt/intelligence/app
COPY config /opt/intelligence/config
ENV PYTHONPATH=/opt/intelligence PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
# Preserve upstream's s6 entrypoint for the dashboard. Jobs override command.
