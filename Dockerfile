# Use a slim, supported Python base
FROM python:3.12-slim

# Do not buffer stdout/stderr (helps logs appear immediately)
ENV PYTHONUNBUFFERED=1
# Default port expected by Cloud Run
ENV PORT=8080
# Ensure /app is on PYTHONPATH so "webapp" imports work
ENV PYTHONPATH=/app

WORKDIR /app

# Install system deps needed for some wheels, for running gunicorn and to fix CRLF issues
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential ca-certificates curl dos2unix && \
    rm -rf /var/lib/apt/lists/*

# Copy Python requirements and install them
COPY src/requirements.txt /app/requirements.txt
RUN python -m pip install --upgrade pip setuptools wheel && \
    pip install --no-cache-dir -r /app/requirements.txt

# Copy application sources
COPY src /app

# Copy entrypoint script, normalize line endings and make executable
COPY scripts/entrypoint.sh /app/entrypoint.sh
RUN dos2unix /app/entrypoint.sh || true
RUN chmod +x /app/entrypoint.sh

# Expose the port (informational)
EXPOSE 8080

# Run entrypoint which will use gunicorn (preferred) or fallback to direct run
ENTRYPOINT ["/app/entrypoint.sh"]
