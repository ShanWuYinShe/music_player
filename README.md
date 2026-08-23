# Music Player

这个仓库同时包含在线音乐服务的客户端与服务端（组织方式与 media_center 一致）：

- `music_app`：HarmonyOS 音乐播放器客户端（ArkTS + ArkUI，Stage 模型），零第三方运行时依赖。支持本地曲库导入（系统音频选择器 + ID3v2 解析）、完整播放控制、后台播放与系统媒体中心接入；在线源接口已预留，后续对接 `music_server`。
- `music_server`：Go 实现的在线音乐服务，扫描服务器本地曲库目录，提供曲目列表、搜索与 HTTP Range 流式播放。纯标准库实现、零第三方依赖，不对接任何第三方音乐 API，曲目由运维向曲库目录投放音频文件。

客户端通过设置页配置服务端 Base URL，外部统一经 nginx 以 `/api/music/` 前缀访问（去前缀转发）。代理 / 部署基础设施（nginx、xray、admin 面板等）在 [workwork](https://github.com/ShanWuYinShe/workwork) 仓库，并通过 git submodule 引用本仓库来构建 `music_server`。

## 目录结构

```
music_app/          HarmonyOS 客户端工程（DevEco Studio 打开此目录）
music_server/       Go 服务端（Dockerfile + 单元测试）
```

## 构建

### music_app（HarmonyOS 客户端）

构建、签名、模拟器运行与单元测试命令见 [music_app/README.md](music_app/README.md)。

### music_server（Go 服务端）

```bash
go build -C music_server -o /dev/null .   # 编译检查
go test -C music_server ./...             # 单元测试
```

本地快速体验（曲库目录投放「歌手 - 歌名.ext」命名音频后）：

```bash
LIBRARY_DIR=/tmp/music-library PORT=8790 go run -C music_server .
curl 'http://127.0.0.1:8790/api/songs?q=关键词'
```

API 字段、文件名约定与部署说明见 [music_server/AGENTS.md](music_server/AGENTS.md)。

## 后续计划

- 客户端接入在线源：实现 `OnlineSource`，按设置页 Base URL 对接 `music_server` 的 providers / songs / stream API
- 歌词显示、桌面卡片、自建歌单
