# music_player（在线音乐：客户端 + 服务端）

通用约束（Git 规范、Commit 格式、验证流程、工具链偏好等）以全局 `~/AGENTS.md` 为准，本文件只做项目特有补充，不得放宽或违背全局约束。

本仓库同时包含 HarmonyOS 客户端 `music_app/` 与 Go 服务端 `music_server/`，
组织方式与 media_center 一致；独立站部署配置在本仓 `deploy/`
（music.chaoset.com：nginx + music_server + netease_api 三服务自洽，
版本唯一来源 `deploy/versions.env`）。

## 架构事实

- `music_app/`：HarmonyOS 应用（ArkTS + ArkUI，Stage 模型），零第三方运行时依赖；工程级技术约束（AVPlayer 状态机、AVSession、V2 状态管理等）见 [music_app/AGENTS.md](music_app/AGENTS.md)
- `music_server/`：纯 Go 标准库 HTTP 服务，零第三方依赖；聚合本地曲库目录（扫描/搜索/Range 流式播放，元数据从文件名解析）与网易云网络源（netease.go，上游 NeteaseCloudMusicApi Enhanced，搜索聚合 + 服务端代理流，失败降级），API 与运维约定见 [music_server/AGENTS.md](music_server/AGENTS.md)
- 播放页舞台双态互斥：封面模式（模糊封面氛围背景 + 大封面，可视化停渲染）与可视化模式（纯全屏 shader）二选一；pan/aurora 场景有状态预通道与按场景渲染比例的性能架构（详见 [music_app/AGENTS.md](music_app/AGENTS.md)）
- 在线源契约：客户端 `OnlineSource.fetchSongs(q)` 走 `/songs`（q 非空=服务端搜索并聚合网络源，q 为空=服务器曲库+网易新歌推荐），播放走 `/stream/{id}`（网络源曲目由服务端代理转发，客户端无感知）；服务地址设置留空回落默认 `https://music.chaoset.com/api/v1`（业务接口规范前缀 `/api/v1`；`/api/*` 过渡别名不存在，访问即 404），`https://yinghuoren.com/api/music` 不可用，需在设置页手填新地址。客户端行为细节（SWR 缓存、VIP 标注、失败熔断等）见 [music_app/AGENTS.md](music_app/AGENTS.md)「在线源」节。

## 本地命令

- Go 侧：构建/检查/测试/运维自检命令以 [music_server/AGENTS.md](music_server/AGENTS.md) 为唯一维护处，此处不重复。
- HarmonyOS 侧：`music_app/` 目录内执行 hvigor/ohpm 命令（工具链与签名约束见 music_app/AGENTS.md 的「本地命令」）。

## CI 门禁与本地验证分工

重活（全量测试、构建、打包、E2E、镜像构建）一律交给 GitHub Actions，本地只跑秒级检查。
完整流程见全局 skill `github-ci-flow`：开发分支推送 → `gh pr create` → `gh pr checks --watch`
全绿 → `gh pr merge --rebase --delete-branch` → 本地 `git pull --ff-only` 并清理 worktree。

- 本地（提交前，秒级）：
  - Go：`gofmt -l music_server/`（应无输出）+ `cd music_server && go build ./... && go vet ./...`（本机实测均 <1s）。
  - shader_playground：`pnpm run lint`（biome；需先在 `shader_playground/` 执行 `pnpm install --frozen-lockfile`，未装依赖时交 CI）；类型检查/构建与单测交 CI。
  - **不跑**：`go test ./...`（全量/含 `-race`）、`pnpm test`、`pnpm run build`、`docker build`。
- CI 覆盖（`.github/workflows/ci.yml`，`push: main` + `pull_request: main`，共 2 个 job）：
  - `Music Server (Go)`：gofmt、go vet、go build、`go test -race -count=1 ./...`。
  - `Shader Playground (Vite)`：`pnpm install --frozen-lockfile`、biome lint、vitest、`tsc + vite build`。
- CI 覆盖不到、必须本地/真机验证的：**鸿蒙端 `music_app/`**——hvigor 构建依赖本机 DevEco 工具链与签名材料，CI 不覆盖，构建/HAP 打包/模拟器与真机走查必须在本地按 `music_app/AGENTS.md`「本地命令」执行（签名材料与设备绑定约束见该文件；真机调试见 skill `music-app-device-debug`）。**发版/发布门禁不变**：交付 HAP 前必须在本地完成 hvigor 签名构建并在端上验证。
- 镜像构建：本仓 CI 无镜像构建 job；`deploy/` 生产镜像由部署服务器 `make build` 构建（交付链路，不是开发机本地验证），本地不做 `docker build`。
- 发版/发布门禁不变：服务端发布按 `deploy/README.md`（git tag 驱动版本，`deploy/Makefile` 取 `git describe`）。


