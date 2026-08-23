# music_server — 在线音乐服务

Go HTTP 服务:从本地曲库目录(LIBRARY_DIR)扫描音频文件,提供曲目列表/搜索与
HTTP Range 流式播放。零第三方依赖(纯标准库),不做任何上游第三方 API 调用。

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

## 文件名约定

元数据从文件名解析,不做 ID3/元数据块解析:

- `歌手 - 歌名.ext` → artist=歌手, title=歌名
- 兼容可选序号前缀:`01_歌手 - 歌名.ext` / `01-歌手 - 歌名.ext`(与
  music_app rawfile 的 `demoXX_歌手 - 歌名.wav` 命名习惯兼容)
- 无「 - 」分隔时整体作为标题,歌手为空
- 一级子目录名作为专辑名
- 时长不解析(durationMs 恒 0),由客户端 prepared 后回填

## API(nginx 去前缀后,外部路径为 /api/music/<path>)

| 端点 | 说明 |
|------|------|
| `GET /health` | healthcheck,无限流 |
| `GET /api/providers` | 源列表(当前仅内置 library 源) |
| `GET /api/songs?q=&limit=` | 曲目列表/模糊搜索(q 匹配标题+歌手,不分大小写;limit 默认 200 上限 500) |
| `GET /api/stream/{id}` | 音频流,ServeContent 原生 Range 支持 |

- id 为曲库相对路径 sha256 前 16 位 hex,磁盘路径不对外暴露,无路径穿越面
- 曲库索引 60s TTL 懒刷新,文件增删最迟一个 TTL 生效
- per-IP 限流(默认 120 req/min,env `RATE_LIMIT_PER_MINUTE`),取 IP 顺序与
  media_server 一致(X-Real-IP → X-Forwarded-For 首段 → RemoteAddr 兜底)

## 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `HOST` | 0.0.0.0 | 监听地址 |
| `PORT` | 8790 | 监听端口 |
| `LIBRARY_DIR` | /data/library | 曲库目录(容器内 ro 挂载) |
| `RATE_LIMIT_PER_MINUTE` | 120 | per-IP 限流阈值 |

## 部署

部署编排(nginx、compose 等)在 workwork 仓库,本仓库 music_server 作为其
submodule 被构建。音频文件投放到宿主机 `service/.wework/music-library/`
(compose ro 绑定挂载),然后 `docker compose build music_server && docker
compose up -d --no-deps music_server`。新增音频无需重启服务,等待扫描 TTL 即可。
