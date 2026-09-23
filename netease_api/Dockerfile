# netease_api:网易云 API 上游(NeteaseCloudMusicApi Enhanced 社区延续分支,
# npm 包 @neteasecloudmusicapienhanced/api),仅容器内网供 music_server 调用。
# 原版 Binaryify 已于 2024.03 停止维护,选用活跃维护的 Enhanced 分支;
# 运行时用 Bun(与仓库 admin 前端构建同基础镜像,ZMusic 等社区部署亦以 Bun 运行,
# 兼容性已实测)。
ARG BUN_VERSION=1.3.14
ARG API_VERSION=4.29.11
ARG APK_MIRROR=mirrors.aliyun.com

FROM oven/bun:${BUN_VERSION}-alpine

# 固定版本全局安装;BUN_INSTALL=/usr/local 使 bin 链接进 PATH(app.js)。
RUN sed -i "s#dl-cdn.alpinelinux.org#${APK_MIRROR}#g" /etc/apk/repositories \
    && apk add --no-cache wget \
    && BUN_INSTALL=/usr/local bun add -g @neteasecloudmusicapienhanced/api@${API_VERSION} \
        --registry=https://registry.npmmirror.com \
    && adduser -D -u 10001 apiuser

ENV HOST=0.0.0.0 \
    PORT=3000

USER apiuser

LABEL org.opencontainers.image.version="${API_VERSION}"

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:3000/ || exit 1

CMD ["/usr/local/bin/api"]
