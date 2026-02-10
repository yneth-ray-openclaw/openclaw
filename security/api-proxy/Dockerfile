# Stage 1: Build static healthcheck binary
FROM golang:1.22-alpine AS healthcheck-builder
COPY healthcheck/main.go /src/main.go
WORKDIR /src
RUN CGO_ENABLED=0 go build -ldflags='-s -w' -o /healthcheck main.go

# Stage 2: Chainguard nginx with njs — no shell, no package manager
FROM cgr.dev/chainguard/nginx:latest

COPY --from=healthcheck-builder /healthcheck /usr/local/bin/healthcheck
COPY api-proxy/nginx.conf /etc/nginx/nginx.conf
COPY api-proxy/token_refresh.js /etc/nginx/njs/token_refresh.js

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ["/usr/local/bin/healthcheck"]

EXPOSE 8080 8081 8082 8083 8084 8085 8086
