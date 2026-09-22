# music_server — 在线音乐服务

Go HTTP 服务:聚合两类曲目来源——本地曲库目录(LIBRARY_DIR 扫描)与网易云
网络源(经私有部署的 [NeteaseCloudMusicApi Enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced)
上游,workwork 编排的 netease_api 容器)。零第三方 Go 依赖(纯标准库);
网络源失败自动降级为仅本地曲库。

## 曲库约定（指针）

本地命令（运维自检）、文件名约定、曲目来源与 id 空间的完整说明见 skill
`music-server-library`。要点：

- 本地曲库文件名约定由 `fillFromFileName` 解析；改解析逻辑前先加载该 skill。
- 曲目 id 分本地/网络两个空间，勿混。

## API(下表按内部路由书写)

对外规范前缀是 `/api/v1`(独立站约定,`main.go` 的 routes() 把 `/api/v1/x`
归一为 `/api/x`);旧 `/api/*` 为过渡期废弃别名,行为与 `/api/v1/*` 完全一致。
独立站部署下经 nginx 原样透传;workwork 过渡反代期间旧路径
`/api/music/<path>` 由其重写后到达。

| 端点 | 说明 |
|------|------|
| `GET /health` | healthcheck,无限流 |
| `GET /healthz` | 存活探针(独立站约定,无鉴权,nginx /healthz 直达),无限流 |
| `GET /api/health` | `/health` 的别名,公网排障可直接拿版本号,无限流 |
| `GET /api/providers` | 源列表(library + 启用的 netease);netease 源带 `loggedIn`(是否已配置账号 cookie) |
| `GET /api/songs?q=&limit=` | q 空:本地曲库全量 + 网易「新歌速递」推荐追加(在线页开箱即有内容);q 非空:本地匹配在前、网易搜索(≤30 条)追加;limit 默认 200 上限 500 |
| `GET /api/stream/{id}` | 音频流,Range 支持(本地 ServeContent / 网络源代理透传);无版权网络曲目返回 404 |

- 网络源曲目带 `vip` 标记(fee=1/4 付费曲目):服务端未配置 cookie 时上游只发
  30~60s 试听片段,客户端据此显示「试听」提示;`loggedIn` 与 `vip` 组合即完整语义

- 本地曲库 id 不暴露磁盘路径,无路径穿越面;网络源直链域名仅允许 http(s)
- 曲库索引 60s TTL 懒刷新,文件增删最迟一个 TTL 生效
- per-IP 限流(默认 120 req/min,env `RATE_LIMIT_PER_MINUTE`),取 IP 顺序与
  media_server 一致(X-Real-IP → X-Forwarded-For 首段 → RemoteAddr 兜底);
  转发头仅当直连方为内网/回环(即 nginx 所在 Docker bridge)时才采信,
  防止公网直连时伪造 `X-Real-IP` 旋转限流键

## 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `HOST` | 0.0.0.0 | 监听地址 |
| `PORT` | 8790 | 监听端口 |
| `LIBRARY_DIR` | /data/library | 曲库目录(容器内 ro 挂载) |
| `RATE_LIMIT_PER_MINUTE` | 120 | per-IP 限流阈值 |
| `NETEASE_API_BASE` | (空=禁用) | netease_api 上游地址(compose 内 `http://netease_api:3000`) |
| `NETEASE_MUSIC_COOKIE` | (空) | 可选:网易账号 cookie 初值(文件不存在时生效) |
| `NETEASE_COOKIE_FILE` | (空) | 可选:cookie 文件路径(扫码登录写入,热加载优先) |
| `MUSIC_SERVER_APP_API_TOKEN` | (空=不鉴权) | 可选:配置后全部业务端点要求 `X-App-Token` 头(与 media_server 的 `MEDIA_SERVER_APP_API_TOKEN` 同构),作为边缘误配/内网横向的兜底 |

## 部署

部署编排(nginx、netease_api、compose 等)在 workwork 仓库,本仓库
music_server 作为其 submodule 被构建。本地曲库音频经管理面板「音乐曲库」
页上传(写宿主机 workwork 仓库根 `.wework/music-library/`,compose 挂载),或手动
投放;发布构建在 workwork 仓库执行 `make build music_server && make up
music_server`(直接 `docker compose build` 不经 make 时镜像版本烙为 "dev",
仅限本地验证,不得用于发布)。发布前必须打 git tag(SemVer,如 v1.0.0):
Dockerfile 的 GIT_VERSION 由编排层 `git describe` 取得并烙进二进制(/health
与启动日志可见),无 tag 时版本号退化为 commit/dev。新增音频无需重启服务,
等待扫描 TTL 即可。
