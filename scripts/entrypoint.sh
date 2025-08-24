#!/usr/bin/env bash
# Minimal entrypoint: normalize env, ensure certs, run gunicorn.
set -euo pipefail

# Use defaults if not provided
: "${PORT:=8080}"
: "${GUNICORN_WORKERS:=2}"
: "${GUNICORN_THREADS:=4}"

# If a requests CA bundle or SSL_CERT_FILE was provided (e.g. for Zscaler),
# prefer REQUESTS_CA_BUNDLE then SSL_CERT_FILE. Export SSL_CERT_FILE for Python's requests.
if [ -n "${REQUESTS_CA_BUNDLE:-}" ]; then
  export SSL_CERT_FILE="${REQUESTS_CA_BUNDLE}"
elif [ -n "${SSL_CERT_FILE:-}" ]; then
  export SSL_CERT_FILE="${SSL_CERT_FILE}"
fi

# If a combined cert file is included in the project under .certs/, prefer it
if [ -f "/app/.certs/certifi_with_zscaler.pem" ] && [ -z "${SSL_CERT_FILE:-}" ]; then
  export SSL_CERT_FILE="/app/.certs/certifi_with_zscaler.pem"
fi

# If SSL_CERT_FILE is set but not readable, warn and continue (Cloud Run may use system store)
if [ -n "${SSL_CERT_FILE:-}" ] && [ ! -f "${SSL_CERT_FILE}" ]; then
  echo "[entrypoint] WARNING: SSL_CERT_FILE set to '${SSL_CERT_FILE}' but file not found."
fi

# Start the app using gunicorn (preferred)
# webapp module is expected to be importable via PYTHONPATH=/app and expose `app`.
exec gunicorn \
  --bind "0.0.0.0:${PORT}" \
  --workers "${GUNICORN_WORKERS}" \
  --threads "${GUNICORN_THREADS}" \
  --timeout 0 \
  --log-level info \
  "webapp:app"
