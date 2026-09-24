# Music Player

这个仓库同时包含在线音乐服务的客户端与服务端（组织方式与 media_center 一致）：

- `music_app`：HarmonyOS 音乐播放器客户端（ArkTS + ArkUI，Stage 模型），零第三方运行时依赖。支持本地曲库导入（系统音频选择器 + ID3v2 解析）、完整播放控制、后台播放与系统媒体中心接入；支持「本地 / 在线」源切换，默认对接线上服务，在线搜索与流式播放 `music_server` 曲库。
- `music_server`：Go 实现的在线音乐服务，聚合本地曲库目录（扫描、搜索、Range 流式播放）与网易云网络源（经私有部署的 NeteaseCloudMusicApi Enhanced 上游聚合搜索、服务端代理播放）。纯标准库实现、零第三方 Go 依赖；本地曲库音频经管理面板上传或手动投放，网络源上游失败自动降级为仅本地。

客户端默认使用线上服务 `https://music.chaoset.com/api/v1`（设置页可改，留空即用默认；业务接口规范前缀 `/api/v1`）。部署为本仓库内自洽编排：`deploy/`（nginx + music_server + netease_api 三服务 compose，独立 bridge 与数据目录，与 workwork 聚合栈零互通）——**本仓库不再是 workwork 的 submodule**。服务端发布前须在仓库打 git tag（SemVer，如 v1.0.0）：`deploy/Makefile` 取 `git describe` 作 build arg，无 tag 时版本号退化为 commit/dev。

## 目录结构

```
music_app/          HarmonyOS 客户端工程（DevEco Studio 打开此目录）
music_server/       Go 服务端（Dockerfile + 单元测试；由本仓库 deploy/ 编排构建）
shader_playground/  GLSL 着色器实验场（Vite + TS，pnpm 管理）
tools/              music_app 签名脚本（auto_sign.sh 等按脚本自身位置解析仓库根，任意目录可执行）
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

- 在线源升级：在线歌单、喜欢/最近跨源聚合、网络源更多平台
- 歌词显示、桌面卡片、自建歌单
