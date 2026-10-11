# music_server — 在线音乐服务

Go HTTP 服务:聚合两类曲目来源——本地曲库目录(LIBRARY_DIR 扫描)与网易云
网络源(经私有部署的 [NeteaseCloudMusicApi Enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced)
上游,本仓 deploy/ 编排的 netease_api 容器,原由 workwork 编排、已迁入本仓,见「部署」节)。零第三方 Go 依赖(纯标准库);
网络源失败自动降级为仅本地曲库。

## 曲库约定（指针）

本地命令（运维自检）、文件名约定、曲目来源与 id 空间的完整说明见 skill
`music-server-library`。要点：

- 本地曲库文件名约定由 `fillFromFileName` 解析；改解析逻辑前先加载该 skill。
- 曲目 id 分本地/网络两个空间，勿混。

## API(下表按内部路由书写)

对外业务前缀是 `/api/v1`(独立站约定),路由直接以该前缀书写;过渡期旧
别名 `/api/*` 已移除(404),workwork 过渡反代与按旧默认地址轮询的存量
安装不再可用,需在 App 设置页手填新地址。独立站部署下经 nginx 原样透传。

| 端点 | 说明 |
|------|------|
| `GET /health` | healthcheck,无限流 |
| `GET /healthz` | 存活探针(独立站约定,无鉴权,nginx /healthz 直达),无限流 |
| `GET /api/v1/health` | `/health` 的带前缀别名,公网排障可直接拿版本号,无限流 |
| `GET /api/v1/providers` | 源列表(library + 启用的 netease);netease 源带 `loggedIn`(是否已配置账号 cookie) |
| `GET /api/v1/songs?q=&limit=` | q 空:本地曲库全量 + 网易「新歌速递」推荐追加(在线页开箱即有内容);q 非空:本地匹配在前、网易搜索(≤30 条)追加;limit 默认 200 上限 500 |
| `GET /api/v1/stream/{id}` | 音频流,Range 支持(本地 ServeContent / 网络源代理透传);无版权网络曲目返回 404 |

- 网络源曲目带 `vip` 标记(fee=1/4 付费曲目):服务端未配置 cookie 时上游只发
  30~60s 试听片段,客户端据此显示「试听」提示;`loggedIn` 与 `vip` 组合即完整语义

- 本地曲库 id 不暴露磁盘路径,无路径穿越面;网络源直链域名仅允许 http(s)
- 曲库索引 60s TTL 懒刷新,文件增删最迟一个 TTL 生效
- 曲库按子目录递归扫描(一级子目录名即专辑):管理端点 `/admin/api/v1/library`
  的 `name` 是**相对曲库根目录的 slash 路径**(如 `专辑/歌.mp3`),与
  `/api/v1/songs` 同构;删除据此寻址子目录文件,路径经 `validMusicRelPath`
  拒绝绝对路径/`..`/空段。上传一律落根目录(仅认文件名)
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
| `MUSIC_SERVER_ADMIN_TOKEN` | (空=不鉴权) | 可选:配置后 /admin/api/v1/* 要求 `X-Admin-Token` 头(常量时间比较) |

## 部署

**部署编排已在本仓库内自洽**：`deploy/` 是 nginx + music_server + netease_api
三服务 compose，独立 bridge 与独立数据目录，与 workwork 聚合栈零互通；
`netease_api` 也已从 workwork 迁入本仓。**不再是 workwork 的 submodule**——
workwork 已无本仓库检出，不要再按 submodule 理解，也不要再去该仓库找部署入口。

本地曲库音频经管理面板「音乐曲库」页上传（写服务器宿主 `deploy/data/library/`，
compose 挂载；首次部署需从旧位置迁移快照，见 `deploy/README.md`），或手动投放。

发布构建在本仓库 `deploy/` 目录执行：`make build music_server && make up music_server`
（直接 `docker compose build` 不经 make 时镜像版本烙为 "dev"，仅限本地验证，不得用于发布）。
发布前必须打 git tag（SemVer，如 `v1.0.0`）：`deploy/Makefile` 以
`git -C .. describe --always --tags --dirty` 取版本并作为 build arg 传入，
Dockerfile 烙进二进制（`/health` 与启动日志可见），无 tag 时退化为 commit/dev。
新增音频无需重启服务，等待扫描 TTL 即可。
