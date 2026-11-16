FROM caddy:2.11.9-builder AS builder

ARG GOPROXY=https://goproxy.cn,direct
ARG GOSUMDB=sum.golang.google.cn

ENV GOPROXY=${GOPROXY} \
    GOSUMDB=${GOSUMDB}

RUN xcaddy build v2.11.9 \
    --with github.com/caddy-dns/duckdns@v0.5.0

FROM caddy:2.11.9-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
