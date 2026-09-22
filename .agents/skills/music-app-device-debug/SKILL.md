---
name: music-app-device-debug
description: music_app 真机/模拟器调试连接与安装：hdc 无线调试自动发现（端口 30000+ 随机、无需用户提供地址）、tconn 超时与僵尸连接处理、一键签名构建安装、安装后验证。触发：装到真机/模拟器；无线调试连不上；hdc tconn 超时或 list targets 为空/Offline；要查设备 IP 端口；uitest 布局/点击/截图验证。
---

# music_app 真机调试连接与安装

目标：用户不再提供 IP:端口，AI 每次按本流程自己找到设备、装上验证。无线调试端口 30000+ 且每次重开会变，手机 IP 也可能变（DHCP/随机 MAC），**禁止写死任何地址**。

## 工具链

- hdc：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`
- 模拟器：`/Applications/DevEco-Studio.app/Contents/tools/emulator/Emulator -list|-start <name>|-stop <name>`
- 一键签名构建安装：仓库根 `tools/auto_sign.sh`（不带参数=只构建；`install`=构建+安装+启动）。它自己会校验签名材料、profile 有效期、设备绑定，失败会打印去 IDE 重签名的指引。
- 沙盒下构建必须重定向缓存（否则 `EPERM ~/.hvigor` / `~/.npm` 失败）：
  `HVIGOR_USER_HOME=$PWD/.workwork/hvigor-home npm_config_cache=$PWD/.workwork/npm-cache tools/auto_sign.sh install`

## 设备自动发现（按序执行，命中即停）

1. **`hdc list targets -v`**：已有 `Connected` 设备直接用，并把 `ip:port` 记入状态文件（见下）。
2. **状态文件**：主仓 `.workwork/hdc-known`（`/.workwork/` 已 gitignore，不入库；worktree 下跑时先取主仓：`git worktree list | head -1 | awk '{print $1}'`），内容为上次成功的 `ip:port`，逐行 `timeout 15 hdc tconn <addr>` 试连。
3. **局域网扫描**（状态文件失效时）：`arp -a` 取同网段候选（排除网关/本机/组播），`ping -c2` 确认存活，然后 asyncio 全端口扫描（1–65535，并发 1000，超时 0.6s，局域网约 1–2 分钟），对每个开放端口 `timeout 12 hdc tconn ip:port` 试握手。
4. **判定标准只有一条**：`hdc list targets -v` 出现 `Connected`。其他一律不算成功。
5. 全部失败 = 手机端无线调试没开（实测：端口通但握手全挂、tconn 反复超时就是这个状态）。**停下来请用户开**（开发者选项 → 无线调试 → 打开，把屏幕上显示的 IP:port 发过来），不要死循环重扫。拿到地址后同样记入状态文件。

## hdc 已踩坑（以实测为准，不要凭记忆假设）

- `tconn` 的退出码不可靠：hang 住时靠外层 `timeout` 杀（exit=124），成功时无输出，`[Fail]Xxx failed` 才是明确失败。一律用 `list targets -v` 复核。
- `tconn <裸IP>`（不带端口）会秒失败，不要用；必须 `ip:port` 全地址。
- 失败/超时会留下 `Offline`/`Unknown` 僵尸条目，`auto_sign.sh` 的设备预检会被它们误导（`grep '^[0-9A-Za-z]'` 能匹配上）。动手前/失败后用 `hdc kill -r`（+ `start -r`）重启 server 清掉，`list targets` 回到 `[Empty]` 再继续。
- 早前挂起的 `tconn` 可能把 server 卡住：表现为之前秒失败的地址也开始 hang。同样 `kill -r` 恢复。
- `tconn` 单次超时设 12–15s（局域网足够）；端口扫描用 python asyncio，不要装 nmap（没装也不需要）。
- 沙盒 `workspace-write` 下 LAN 直连与扫描均可正常执行，已验证。

## 安装与验证

- 安装：`tools/auto_sign.sh install`（连上设备后；它会重建 signed HAP 再 `hdc install -r` + `aa start`）。
- 存活：`hdc shell "pidof com.lsyb.musicplayer; bm dump -n com.lsyb.musicplayer" | head`。
- UI：`hdc shell uitest dumpLayout` 取布局树（应用 root 在 children[0]，children 为空=白屏未渲染）；`hdc shell uinput -T -c <x> <y>` 点；`snapshot_display` 截图（截图落盘后用 read_image 看）。
- 包名：`com.lsyb.musicplayer`，入口 `EntryAbility`。
