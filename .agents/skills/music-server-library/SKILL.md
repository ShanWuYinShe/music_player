---
name: music-server-library
description: music_server 本地曲库约定：文件名解析约定、曲目来源与 id 空间、运维自检命令。触发：改曲库扫描或文件名解析；排查曲目 id 冲突或来源判定；跑运维自检。
---

# music_server 曲库约定与 id 空间

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
