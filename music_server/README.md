# music_server

music_player 仓库的在线音乐服务:扫描服务器本地曲库目录,为同仓库的
HarmonyOS 客户端 [music_app](../music_app)提供曲目列表、搜索与 HTTP Range
流式播放。

- 纯 Go 标准库实现,零第三方依赖,静态编译,内存占用极低
- 不对接任何第三方音乐 API,曲目完全由运维向曲库目录投放音频文件
- 元数据从文件名解析,约定见 [AGENTS.md](AGENTS.md)

## 快速开始(本地)

```bash
mkdir -p /tmp/music-library
# 按「歌手 - 歌名.ext」命名放入音频文件
LIBRARY_DIR=/tmp/music-library PORT=8790 go run .
curl 'http://127.0.0.1:8790/api/songs?q=关键词'
```

## API

外部统一经 nginx 以 `/api/music/` 前缀访问(去前缀转发到服务):

```
GET /api/music/providers          # 源列表
GET /api/music/songs?q=&limit=    # 列表/搜索
GET /api/music/stream/<id>        # 音频流(支持 Range)
```

完整字段与运维说明见 [AGENTS.md](AGENTS.md)。
