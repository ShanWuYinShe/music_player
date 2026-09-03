# music_player（在线音乐：客户端 + 服务端）

本仓库同时包含 HarmonyOS 客户端 `music_app/` 与 Go 服务端 `music_server/`，
组织方式与 media_center 一致；部署基础设施在 workwork 仓库（本仓库作为其
submodule，music_server 由 workwork 的 docker-compose 构建）。

## 架构事实

- `music_app/`：HarmonyOS 应用（ArkTS + ArkUI，Stage 模型），零第三方运行时依赖；工程级技术约束（AVPlayer 状态机、AVSession、V2 状态管理等）见 [music_app/AGENTS.md](music_app/AGENTS.md)
- `music_server/`：纯 Go 标准库 HTTP 服务，零第三方依赖；聚合本地曲库目录（扫描/搜索/Range 流式播放，元数据从文件名解析）与网易云网络源（netease.go，上游 NeteaseCloudMusicApi Enhanced，搜索聚合 + 服务端代理流，失败降级），API 与运维约定见 [music_server/AGENTS.md](music_server/AGENTS.md)
- 播放页舞台双态互斥：封面模式（模糊封面氛围背景 + 大封面，可视化停渲染）与可视化模式（纯全屏 shader）二选一；pan/aurora 场景有状态预通道与按场景渲染比例的性能架构（详见 [music_app/AGENTS.md](music_app/AGENTS.md)）
- 客户端在线源已实现：首页「本地/在线」源切换，`OnlineSource.fetchSongs(q)` 拉取 `/songs`（q 非空走服务端搜索并聚合网络源，q 为空=服务器曲库+网易新歌推荐；解析纯函数在 `source/OnlineApi.ets`，可 LocalUnit 单测），播放走 `/stream/{id}`（网络源曲目由服务端代理转发，客户端无感知）；本地曲库时长由服务端解析容器元数据返回（durationMs），客户端 prepared 后仍会校准；在线搜索由 Index 防抖 600ms 触发，列表即服务端返回不做本地二次过滤；在线页同时拉 `/providers`（`fetchProviders`）获取网易云登录态，未登录时展示「VIP 歌曲仅 30 秒试听」横幅，曲目 `vip` 字段驱动 VIP 徽标与播放页「VIP 试听」标注；播放失败（无版权/网络错误）由 `PlayerController.handlePlaybackFailure` 统一 toast + 自动跳下一首，连续 3 首失败熔断；服务地址设置页持久化，**留空回落默认 `https://yinghuoren.com/api/music`**（`effectiveBaseUrl`，配置值需含 `/api[/music]` 前缀）；服务端对外经 nginx `/api/music/` 前缀（workwork 仓库 nginx 去前缀转发到 8790）

## 本地命令

Go 侧（在仓库根执行）：

```bash
go build -C music_server -o /dev/null .   # 编译检查
go vet -C music_server ./...               # 静态检查
gofmt -l music_server/                     # 格式化检查
go test -C music_server ./...               # 单元测试
go run -C music_server . -library-review   # 运维自检:扫描曲库打印解析结果
```

HarmonyOS 侧：`music_app/` 目录内执行 hvigor/ohpm 命令（工具链与签名约束见 music_app/AGENTS.md 的「本地命令」）。
