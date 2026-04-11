FROM python:3.13-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    FIXWISE_DATABASE_PATH=/data/fixwise.db \
    FIXWISE_ENVIRONMENT=production

# Production deployments must provide FIXWISE_JWT_SECRET and FIXWISE_MASTER_KEY.

WORKDIR /app

RUN groupadd --system fixwise \
    && useradd --system --gid fixwise --create-home --home-dir /home/fixwise --shell /usr/sbin/nologin fixwise \
    && mkdir -p /data \
    && chown -R fixwise:fixwise /app /data

COPY pyproject.toml ./
COPY src ./src

RUN pip install --upgrade pip \
    && pip install .

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health').read()"

USER fixwise

CMD ["uvicorn", "fixwise_backend.app:app", "--host", "0.0.0.0", "--port", "8000"]
