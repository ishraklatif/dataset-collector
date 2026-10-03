FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements-prod.txt ./
RUN pip install --no-cache-dir -r requirements-prod.txt \
    && groupadd --system collector \
    && useradd --system --gid collector --home-dir /app collector

COPY app.py domain.py gunicorn.conf.py ./
COPY migrations ./migrations

USER collector
EXPOSE 8000
CMD ["gunicorn", "--config", "gunicorn.conf.py", "app:create_app()"]
