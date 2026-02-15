# Stage 1: Build static healthcheck binary
FROM golang:1.22-alpine AS healthcheck-builder
COPY healthcheck/main.go /src/main.go
WORKDIR /src
RUN CGO_ENABLED=0 go build -ldflags='-s -w' -o /healthcheck main.go

# Stage 2: Render nginx config from template + YAML data
FROM hairyhenderson/gomplate:stable-alpine AS template
COPY api-proxy/proxy-services.yaml /work/proxy-services.yaml
COPY api-proxy/nginx.conf.tmpl /work/nginx.conf.tmpl
RUN gomplate -d services=/work/proxy-services.yaml -f /work/nginx.conf.tmpl -o /work/nginx.conf

# Stage 3: Official nginx with njs module
FROM nginx:1.27-alpine

RUN apk add --no-cache nginx-module-njs \
    && rm -rf /var/cache/apk/* \
    && mkdir -p /var/cache/nginx/client_temp \
                /var/cache/nginx/proxy_temp \
                /var/cache/nginx/fastcgi_temp \
                /var/cache/nginx/uwsgi_temp \
                /var/cache/nginx/scgi_temp \
    && chown -R 101:101 /var/cache/nginx /var/run

COPY --from=healthcheck-builder /healthcheck /usr/local/bin/healthcheck
COPY --from=template /work/nginx.conf /etc/nginx/nginx.conf
COPY api-proxy/token_refresh.js /etc/nginx/njs/token_refresh.js

USER 101

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ["/usr/local/bin/healthcheck"]

EXPOSE 8080 8081 8082 8083 8084 8085 8086
