# music_server

music_player 仓库的在线音乐服务:为同仓库的 HarmonyOS 客户端
[music_app](../music_app)提供曲目列表、搜索与 HTTP Range 流式播放。
聚合两类来源——本地曲库目录 + 网易云网络源(可选)。

- 纯 Go 标准库实现,零第三方依赖,静态编译,内存占用极低
- 本地曲库:扫描 LIBRARY_DIR,元数据从文件名解析(约定见 [AGENTS.md](AGENTS.md)),
  音频经管理面板上传或手动投放
- 网络源(可选):经私有部署的 NeteaseCloudMusicApi Enhanced 上游聚合网易云
  搜索与播放,音频由本服务代理转发;上游失败自动降级为仅本地曲库。
  非官方接口仅限个人使用,匿名只可播免费曲目(配 cookie 可解锁更多)

## 快速开始(本地)

```bash
mkdir -p /tmp/music-library
# 按「歌手 - 歌名.ext」命名放入音频文件
LIBRARY_DIR=/tmp/music-library PORT=8790 go run .
curl 'http://127.0.0.1:8790/api/songs?q=关键词'
# 启用网络源(需自行运行 netease_api 上游,见 workwork 编排):
# NETEASE_API_BASE=http://127.0.0.1:3000 LIBRARY_DIR=... go run .
```

## API

外部统一经 nginx 以 `/api/music/` 前缀访问(去前缀转发到服务):

```
GET /api/music/providers          # 源列表
GET /api/music/songs?q=&limit=    # 列表/搜索(q 非空时聚合网络源结果)
GET /api/music/stream/<id>        # 音频流(支持 Range;网络源为服务端代理)
```

完整字段与运维说明见 [AGENTS.md](AGENTS.md)。
