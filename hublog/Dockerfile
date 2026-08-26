FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
# Use a mainland mirror by default; override at build time when needed:
# docker build --build-arg PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/ .
ARG PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
RUN pip install --no-cache-dir --index-url "${PIP_INDEX_URL}" -r requirements.txt
COPY app ./app
COPY migrations ./migrations
USER 10001
EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
