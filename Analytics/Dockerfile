FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN groupadd --system --gid 10001 collector \
    && useradd --system --uid 10001 --gid collector --home-dir /app --shell /usr/sbin/nologin collector \
    && install -d -o collector -g collector -m 0700 /data
WORKDIR /app
COPY --chown=collector:collector collector.py /app/collector.py
USER 10001:10001
EXPOSE 8787
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python3", "-c", "import urllib.request; r=urllib.request.urlopen('http://127.0.0.1:8787/healthz', timeout=2); raise SystemExit(0 if r.status == 204 else 1)"]
ENTRYPOINT ["python3", "/app/collector.py", "serve", "--database", "/data/reports.sqlite", "--bind", "0.0.0.0", "--allow-nonloopback"]
