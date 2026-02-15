# Stage 1: Install Python dependencies
FROM python:3.11-slim AS deps-builder
WORKDIR /app
COPY llm-proxy/requirements.txt .
RUN pip install --no-cache-dir --target=/app/deps -r requirements.txt

# Stage 2: Build static healthcheck binary
FROM golang:1.22-alpine AS healthcheck-builder
COPY healthcheck/main.go /src/main.go
WORKDIR /src
RUN CGO_ENABLED=0 go build -ldflags='-s -w' -o /healthcheck main.go

# Stage 3: Distroless Python runtime — no shell, no package manager
FROM gcr.io/distroless/python3-debian12:nonroot

COPY --from=deps-builder /app/deps /app/deps
COPY llm-proxy/proxy.py /app/proxy.py
COPY --from=healthcheck-builder /healthcheck /usr/local/bin/healthcheck

ENV PYTHONPATH=/app/deps

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/healthcheck"]

EXPOSE 8080

ENTRYPOINT ["python3", "-m", "uvicorn", "proxy:app", "--host", "0.0.0.0", "--port", "8080", "--app-dir", "/app"]
