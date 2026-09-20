# music_server — 在线音乐服务

Go HTTP 服务:聚合两类曲目来源——本地曲库目录(LIBRARY_DIR 扫描)与网易云
网络源(经私有部署的 [NeteaseCloudMusicApi Enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced)
上游,workwork 编排的 netease_api 容器)。零第三方 Go 依赖(纯标准库);
网络源失败自动降级为仅本地曲库。

## 本地命令

在仓库根(music_player/)执行;`-C music_server` 已指定工作目录:

```bash
go build -C music_server -o /dev/null .   # 编译检查
go vet -C music_server ./...               # 静态检查
gofmt -l music_server/                     # 格式化检查
go test -C music_server ./...              # 单元测试
# 运维自检:扫描曲库并打印解析结果(验证文件名约定)
go run -C music_server . -library-review
```

## 文件名约定(本地曲库)

元数据从文件名解析,不做 ID3/元数据块解析:

- `歌手 - 歌名.ext` → artist=歌手, title=歌名
- 兼容可选序号前缀:`01_歌手 - 歌名.ext` / `01-歌手 - 歌名.ext`(与
  music_app rawfile 的 `demoXX_歌手 - 歌名.wav` 命名习惯兼容)
- 无「 - 」分隔时整体作为标题,歌手为空
- 一级子目录名作为专辑名
- 本地曲库时长由 duration.go 解析容器元数据(mp3 Xing/CBR、flac STREAMINFO、
  m4a mvhd、wav fmt+data、ogg/opus 尾页 granulepos),扫描时一次解析进索引;
  解析失败返回 0 由客户端 prepared 后回填;
  netease 源带真实时长

## 曲目来源与 id 空间

| 来源 | source 字段 | id 形态 | 流下发方式 |
|------|------------|---------|-----------|
| 本地曲库 | (省略) | 相对路径 sha256 前 16 hex | 直读文件,ServeContent 原生 Range |
| 网易云网络源 | `netease` | `ne_<上游歌曲数字id>` | 解析时效直链后由本服务反向代理转发 |

- 网络源上游匿名只能播免费曲目且部分仅有 30~60s 试听片段;配置网易账号
  cookie 后返回完整音频。cookie 来源:`NETEASE_COOKIE_FILE` 文件优先
  (管理面板扫码登录写入,30s 热加载,删除文件即登出回匿名),env
  `NETEASE_MUSIC_COOKIE` 为回退初值
- 上游为非官方接口,仅限个人使用,可能随平台变动失效(降级不影响本地源)

## API(nginx 去前缀后,外部路径为 /api/music/<path>)

| 端点 | 说明 |
|------|------|
| `GET /health` | healthcheck,无限流 |
| `GET /api/health` | `/health` 的别名,公网经 `/api/music/health` 排障可直接拿版本号,无限流 |
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
仅限本地验证,不得用于发布)。新增音频无需重启服务,等待扫描 TTL 即可。
