# music_player（在线音乐：客户端 + 服务端）

通用约束（Git 规范、Commit 格式、验证流程、工具链偏好等）以全局 `~/AGENTS.md` 为准，本文件只做项目特有补充，不得放宽或违背全局约束。

本仓库同时包含 HarmonyOS 客户端 `music_app/` 与 Go 服务端 `music_server/`，
组织方式与 media_center 一致；部署基础设施在 workwork 仓库（本仓库作为其
submodule，music_server 由 workwork 的 docker-compose 构建）。

## 架构事实

- `music_app/`：HarmonyOS 应用（ArkTS + ArkUI，Stage 模型），零第三方运行时依赖；工程级技术约束（AVPlayer 状态机、AVSession、V2 状态管理等）见 [music_app/AGENTS.md](music_app/AGENTS.md)
- `music_server/`：纯 Go 标准库 HTTP 服务，零第三方依赖；聚合本地曲库目录（扫描/搜索/Range 流式播放，元数据从文件名解析）与网易云网络源（netease.go，上游 NeteaseCloudMusicApi Enhanced，搜索聚合 + 服务端代理流，失败降级），API 与运维约定见 [music_server/AGENTS.md](music_server/AGENTS.md)
- 播放页舞台双态互斥：封面模式（模糊封面氛围背景 + 大封面，可视化停渲染）与可视化模式（纯全屏 shader）二选一；pan/aurora 场景有状态预通道与按场景渲染比例的性能架构（详见 [music_app/AGENTS.md](music_app/AGENTS.md)）
- 在线源契约：客户端 `OnlineSource.fetchSongs(q)` 走 `/songs`（q 非空=服务端搜索并聚合网络源，q 为空=服务器曲库+网易新歌推荐），播放走 `/stream/{id}`（网络源曲目由服务端代理转发，客户端无感知）；服务地址设置留空回落默认 `https://yinghuoren.com/api/music`（配置值需含 `/api[/music]` 前缀），服务端对外经 nginx `/api/music/` 前缀（workwork 仓库 nginx 去前缀转发到 8790）。客户端行为细节（SWR 缓存、VIP 标注、失败熔断等）见 [music_app/AGENTS.md](music_app/AGENTS.md)「在线源」节。

## 本地命令

- Go 侧：构建/检查/测试/运维自检命令以 [music_server/AGENTS.md](music_server/AGENTS.md) 为唯一维护处，此处不重复。
- HarmonyOS 侧：`music_app/` 目录内执行 hvigor/ohpm 命令（工具链与签名约束见 music_app/AGENTS.md 的「本地命令」）。

## 主题索引（按需加载 skill）

本仓库约定按主题拆为 skill，改对应模块前先加载：

| skill | 何时加载 |
|---|---|
| `music-app-platform-ui` | 改 music_app 的 ArkTS 页面/组件、播放内核、媒体会话、主题资源、播放页手势与舞台、在线源与缓存 |
| `music-app-shader-pipeline` | 改 GLSL shader、增删可视化场景、调帧驱动、接入传感器体感、排查可视化黑屏/闪烁 |
| `music-app-service-card` | 改 form/ 卡片或 FormAbility、卡片进度/按钮异常、卡片配色、麦克风律动、分享卡片图 |
| `music-server-library` | 改曲库扫描/文件名解析、排查曲目 id 与来源判定、跑运维自检 |
