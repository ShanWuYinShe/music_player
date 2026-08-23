ARG GO_VERSION=1.26.5
ARG ALPINE_VERSION=3.24.1

FROM golang:${GO_VERSION}-alpine AS builder

WORKDIR /app

ARG GOPROXY
ENV GOPROXY=${GOPROXY:-https://goproxy.cn,direct}

COPY go.mod ./
RUN go mod download

COPY *.go ./
# TARGETARCH 由 BuildKit 自动注入(buildx --platform),arm64 主机也能构建;
# 无注入时回退 amd64。
ARG TARGETARCH=amd64
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/music_server .

FROM alpine:${ALPINE_VERSION}

WORKDIR /app

RUN sed -i 's#dl-cdn.alpinelinux.org#mirrors.aliyun.com#g' /etc/apk/repositories \
    && apk add --no-cache ca-certificates wget \
    && adduser -D -u 10001 appuser \
    && mkdir -p /data/library \
    && chown -R appuser:appuser /app /data

ENV HOST=0.0.0.0 \
    PORT=8790 \
    LIBRARY_DIR=/data/library

COPY --from=builder /out/music_server /app/music_server

VOLUME ["/data/library"]
EXPOSE 8790

# 编排层感知服务假死:/health 端点在 main.go 注册。
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8790/health || exit 1

USER appuser
CMD ["/app/music_server"]
