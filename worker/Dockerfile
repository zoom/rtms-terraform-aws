FROM python:3.12-slim AS base

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libstdc++6 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY main.py .

# The underlying C++ RTMS SDK writes its internal logs to /app/logs/<lang>_<pid>.
# The path is hardcoded in the C SDK — without this directory, every SDK
# operation spams `failed to open file [/app/logs/python_1] errno = 2` to
# stderr (still functional, just noisy). Pre-create + own it. Tracked as a
# v1.2 SDK improvement (see RTMS SDK v1.2 plan).
RUN mkdir -p /app/logs \
 && useradd -r -u 10001 -m -d /home/worker worker \
 && chown -R worker:worker /app
USER worker

EXPOSE 8080

# Liveness only — verifies the SDK's webhook server is bound to the port.
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD python -c "import socket,sys; s=socket.socket(); s.settimeout(2); s.connect(('127.0.0.1',8080)); s.close()" || exit 1

CMD ["python", "-u", "main.py"]
