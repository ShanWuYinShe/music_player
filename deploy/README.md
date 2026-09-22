# music 站部署（music.chaoset.com）

`music_server` + `netease_api`（自 workwork 迁入）的独立站编排。与 workwork
聚合栈零互通：独立 bridge、独立数据目录、独立版本来源（[versions.env](versions.env)）。
API 约定：业务接口规范前缀 `/api/v1/`，旧 `/api/*` 为过渡期别名；
`GET /healthz` 无鉴权存活探针。

## 首次部署（服务器）

1. **IPv6 寻址**：确认宿主 ipvlan_docker 可分配新地址，写入 `.env` 的
   `MUSIC_IPV6`；Cloudflare 加 `music.chaoset.com` AAAA 记录（DNS 须在服务器
   上操作——CF token 有来源 IP 白名单）。
2. **证书**：`cert/` 放 `server_cert.pem` / `server_cert.key`
   （`*.chaoset.com` 通配符 Origin 证书，与 media 站同一张）与
   `cloudflare-origin-pull.pem`。
3. **CF zone**：chaoset.com 开启 Authenticated Origin Pulls（与 media 站同一
   zone 级设置，做一次即可）。
4. **数据就位**（宿主目录属主须为 uid 1001，容器以 `1001:1001` 运行）：
   - `data/library/`：曲库音频（从 workwork 服务器 `.wework/music-library/`
     rsync 迁移；此后由薄管理端点或 scp 投放）；
   - `data/generated/`：网易云 cookie（`netease-cookie.txt`，可选，扫码登录
     会重新写入）。
5. **启动**：`cp .env.example .env && $EDITOR .env && make build && make up netease_api music_server nginx`。
6. **验证**：`curl -s https://music.chaoset.com/healthz`；App 侧以新基址
   `https://music.chaoset.com/api/v1` 拉一次 songs。

## 运维

- **版本升级**：改 `versions.env` → `make build` → `make up <svc...>`；
  镜像 tag 为 `git describe`（回滚 = `IMAGE_TAG=<旧tag> make up <svc...>`）。
- **曲库投放**：薄管理端点（Phase 2b）上线前经 `scp` 到 `data/library/`；
  文件名约定「歌手 - 歌名.ext」，music_server 自动扫描。
- **网易云登录**：薄管理端点上线前经 `.env` 的 `NETEASE_MUSIC_COOKIE` 或
  cookie 文件投放。
- **过渡期别名**：`/api/*` 仅供 workwork nginx 过渡反代与存量 App，客户端
  全量切换后删除（nginx 模板注释 + music_server `apiV1Prefix` 归一化）。
