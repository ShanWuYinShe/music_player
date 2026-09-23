# music 站部署（music.chaoset.com）

`music_server` + `netease_api`（自 workwork 迁入）的独立站编排。与 workwork
聚合栈零互通：独立 bridge、独立数据目录、独立版本来源（[versions.env](versions.env)）。
API 约定：业务接口规范前缀 `/api/v1/`，旧 `/api/*` 别名已移除（404）；
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
5. **管理入口**：生成基础认证文件
   `mkdir -p htpasswd && htpasswd -nB <user> '<pass>' > htpasswd/.htpasswd（-nB 用 bcrypt,默认 apr1/MD5 已不建议）`
   （容器以 ro 挂载）；管理页 `https://music.chaoset.com/admin/`（曲库上传/
   删除、网易云扫码登录），可选令牌兜底见 `.env` 的 `MUSIC_SERVER_ADMIN_TOKEN`。
6. **启动**：`cp .env.example .env && $EDITOR .env && make build && make up netease_api music_server nginx`。
7. **验证**：`curl -s https://music.chaoset.com/healthz`；App 侧以新基址
   `https://music.chaoset.com/api/v1` 拉一次 songs；浏览器登录 /admin/ 试传一个
   小文件并确认曲库列表出现。

## 版本统一

基础镜像版本由 workwork 仓库的 `versions.env` 作主本统一管理（本仓
`deploy/versions.env` 是其在音乐站的落地）。跨仓校验/同步工具：workwork 仓
`scripts/sync-versions.sh check|sync`；勿单方面修改本仓版本值。

## 运维

- **版本升级**：改 `versions.env` → `make build` → `make up <svc...>`；
  镜像 tag 为 `git describe`（回滚 = `IMAGE_TAG=<旧tag> make up <svc...>`）。
- **曲库投放**：管理页 `/admin/` 批量上传（≤100MB/个）或大文件分片上传
  （8MB/片可续传，绕过 CF 单请求 100MB 上限）；也可 `scp` 到 `data/library/`。
  文件名约定「歌手 - 歌名.ext」，music_server 自动扫描（60s TTL 懒刷新）。
- **网易云登录**：管理页扫码登录（cookie 热加载 30s 内生效）；也可经
  `.env` 的 `NETEASE_MUSIC_COOKIE` 投放。
- **宿主目录属主**：`data/library`、`data/upload-chunks`、`data/generated`（注:当前 compose 未挂载该目录,分片落在容器可写层——容器重建后续传会丢,重新上传即可
  须可被 uid 1001 写入（容器 `user: "1001:1001"`），首次部署
  `chown -R 1001 data`。
- **旧别名已移除**：`/api/*` 一律 404；存量旧版 App（默认 `yinghuoren.com/api/music`）需在设置页手填新地址
  全量切换后删除（nginx 模板注释 + music_server `apiV1Prefix` 归一化）。
