# syntax=docker/dockerfile:1

FROM --platform=$BUILDPLATFORM node:22-alpine AS web-builder

WORKDIR /src/admin-web
COPY admin-web/package.json admin-web/package-lock.json ./
RUN npm ci
COPY admin-web/ ./
RUN npm run build

FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS backend-builder

ARG TARGETOS=linux
ARG TARGETARCH
ARG GOPROXY=https://proxy.golang.org,direct

WORKDIR /src/backend
RUN apk add --no-cache ca-certificates tzdata

COPY backend/go.mod backend/go.sum ./
RUN GOPROXY=${GOPROXY} go mod download

COPY backend/ ./
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} GOPROXY=${GOPROXY} \
    go build -trimpath -ldflags="-s -w" -o /out/oo-music ./cmd/server

FROM alpine:3.22

RUN apk add --no-cache ca-certificates tzdata \
    && addgroup -S -g 10001 app \
    && adduser -S -D -H -u 10001 -G app app \
    && mkdir -p /data /app/web \
    && chown -R app:app /data /app

WORKDIR /app
COPY --from=backend-builder /out/oo-music /app/oo-music
COPY --from=web-builder /src/admin-web/dist/ /app/web/

USER app

ENV OO_MUSIC_ADDR=0.0.0.0:8787 \
    OO_MUSIC_DB_PATH=/data/oo-music.db \
    OO_MUSIC_WEB_DIST=/app/web

EXPOSE 8787
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8787/healthz || exit 1

ENTRYPOINT ["/app/oo-music"]
