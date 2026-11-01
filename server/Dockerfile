FROM node:22-bookworm-slim AS javascript
FROM python:3.12-slim-bookworm
COPY --from=javascript /usr/local/bin/node /usr/local/bin/node
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
RUN useradd --uid 10001 --create-home companion && mkdir -p /data && chown companion /data
USER companion
ENV BETTER_DATA=/data
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8447", "--ssl-keyfile", "/tls/key.pem", "--ssl-certfile", "/tls/cert.pem", "--no-access-log"]
