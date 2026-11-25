---
name: music-app-device-debug
description: music_app 真机/模拟器调试的项目专属部分：设备选择（真机优先，无合格真机才用模拟器；真机需签名 profile 覆盖 UDID）、包名与入口、一键签名构建安装脚本 tools/auto_sign.sh 的用法与前提、安装后存活与界面验证命令、沙盒缓存重定向。触发：把 music_app 装到真机或模拟器；判断该用真机还是模拟器；auto_sign.sh 失败或签名材料/证书过期/设备未绑定；安装后启动白屏或进程不在；用 hdc 验证 music_app 界面。
---

# music_app 设备调试（项目专属部分，真机优先）

**hdc 通用流程（设备自动发现、无线调试连接、tconn 陷阱与僵尸连接清场、uitest 布局与截图验证、沙盒缓存重定向）见用户级 skill `harmony-device-debug`，本文件不复述。**

## 设备选择（真机优先）

先枚举再选设备：**有合格真机就用真机，没有才用模拟器**。完整判定流程（四项合格条件、Fallback 原因记录口径）见用户级 skill `harmony-device-debug` 的「选设备：真机优先，模拟器兜底」节，本文件只写本项目判据。

- 枚举：`hdc list targets -v`——状态列 `Connected` 才算可用（`Offline`/`Unknown` 不算）；ConnectKey 为 `127.0.0.1:*` 的是本地模拟器（本项目实例地址 `127.0.0.1:5555`），其余为真机。模拟器身份用现查命令复核：`hdc -t <ConnectKey> shell param get const.product.model` 返回 `emulator`。
- 本项目真机判据：设备 API（`hdc -t <ConnectKey> shell param get const.ohos.apiversion` 现查）不低于 `compatibleSdkVersion`（`6.0.0(20)`，见 `music_app/build-profile.json5`）；`tools/auto_sign.sh install` 的设备绑定校验通过（脚本读 `hdc shell bm get -u` 的 UDID，用 `tools/parse_profile.py` 与 profile 绑定列表比对，未绑定会打印去 IDE 重签名的指引；本地模拟器 `127.0.0.1:*` 跳过绑定校验）。
- 形态/能力：普通 UI 走查手机真机即可；可视化体感（uTilt/uSpin/uKick）、麦克风律动、音频外放、服务卡片等依赖真实硬件，模拟器结论不算数。
- 数据安全：不擅自卸载/清数据/改系统设置；用户日常机涉及这些操作前先征得同意。
- 选中后所有 hdc 命令固定加 `-t <ConnectKey>`（全局选项放在子命令前，如 `hdc -t <ConnectKey> shell ...`）；走查记录与 PR 证据写明型号（`hdc -t <ConnectKey> shell param get const.product.model` 现查，不靠外观猜）+ 系统版本（`param get const.product.software.version`）+ serial/target（模拟器写实例名与 `127.0.0.1:5555`）。
- `tools/auto_sign.sh install` 不接收 `-t`，按「当前连接的设备」安装；同时连着多台设备（如真机 + 模拟器）时先断开其余设备再跑。

无合格真机 → 用模拟器，并把原因（未连接/未授权/版本不符/签名未绑定/形态不符/需隔离数据）写进走查记录；模拟器专属结论（坐标、性能、无麦等）不得当成真机结论。

## 项目事实

- 包名：`com.lsyb.musicplayer`，入口 `EntryAbility`
- 一键签名构建安装：仓库根 `tools/auto_sign.sh`
  - 不带参数 = 只构建；`install` = 构建 + 安装 + 启动
  - 它自己会校验签名材料、profile 有效期（`install` 模式另校验设备绑定）；失败会打印去 IDE 重签名的指引
- `compatibleSdkVersion`/`targetSdkVersion` 为 `6.0.0(20)`；自动签名由华为账号绑定前缀决定
- **模拟器深色模式切换（仅模拟器；坐标基于 1256x2760 分辨率实例标定，真机与其他实例需重新标定）**：`persist.ace.darkmode`/`persist.sys.dark*` 等 param 参数**全部不存在**（set 报 success 但不生效，get 1002）——唯一路径是**设置 App UI 导航**：`hdc shell aa start -a com.huawei.hmos.settings.MainAbility -b com.huawei.hmos.settings` → 点「显示和亮度」(628,1490) → 深色单选 (905,1620) / 浅色单选 (355,1620)（1256x2760 分辨率坐标，**模拟器专属**）。切换全系统即时生效；切完记得恢复浅色，别把用户模拟器留在深色态

## 本项目验证命令

- **存活**：`hdc shell "pidof com.lsyb.musicplayer; bm dump -n com.lsyb.musicplayer" | head`
- **UI**：`hdc shell uitest dumpLayout` 取布局树（应用 root 在 `children[0]`，`children` 为空 = 白屏未渲染）；`hdc shell uinput -T -c <x> <y>` 点击；截图后 read_image 查看

## 本项目的构建注意事项

- 纯构建（不带参数）不需要连设备：设备校验与安装只发生在 `install` 模式，签名只依赖 `~/.ohos/config/` 材料
- UI 相关改动在真机上验证时，注意 V2 状态不驱动渲染的已知坑（见 skill `music-app-platform-ui`）——**界面没更新不一定是没装上**
- 手机息屏会断开无线调试：重连成功后立刻跑安装，并提醒用户装机期间别锁屏

## 本地单测（isLocalTest）要求 PATH 含 /usr/sbin

`hvigorw ... -p isLocalTest=true test` 会在 `GenerateUnitTestResult` 任务里
调 `@ohos/coverage` 的 `findPort` 探测本地测试端口，**内部依赖 `netstat`/`lsof`**——
macOS 上这两个在 **`/usr/sbin`**（实测）。

**症状极具误导性**（报错完全指向代码，实际是 PATH 问题）：

```
> hvigor ERROR: Failed :entry:default@GenerateUnitTestResult...
> hvigor ERROR: 00305010 Syntax Error
Error Message: Cannot read properties of undefined (reading 'toString')
  > Check whether undefined attributes or methods are used in the hvigorconfig.ts and hvigorfile.ts files.
```

加 `--stacktrace` 才能看到真因：

```
at findPort (.../@ohos/coverage/lib/src/commandLine/localTest/portutil.js:30:28)
at executeCoverageTest (.../previewer.js:113:45)
```

**误判成本很高**：该错误会让人去查代码语法、hvigorfile 配置、清 `.test`/`build`/
`.hvigor` 增量状态、甚至怀疑主检出损坏——**全部无效**。判据：看到
`00305010 Syntax Error` + `Cannot read properties of undefined (reading 'toString')`
且伴随 `GenerateUnitTestResult` 失败时，**先检查 PATH 是否含 `/usr/sbin`**。

```bash
# 正确的完整 PATH（脚本/CI/非交互 shell 里尤其要注意）
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
```

> 注意：交互式登录 shell 通常已含 `/usr/sbin`，所以在自己终端里手跑常常正常，
> 而**用受限 PATH 的程序化调用（agent/CI/脚本）会稳定复现**——排查时容易误以为
> "代码有问题"或"环境玄学"。

## worktree 内构建

**worktree 无 `oh_modules`/`.hvigor`（均被 gitignore），先 `ohpm install`。**
`~/.hvigor`、`~/.ohpm` 已由 DSH sandbox-extra-roots 放行，沙盒内直接构建即可；
未配插件的机器才需 `HVIGOR_USER_HOME` 重定向，**并把该目录指向
`.workwork/`（workspace 中间产物区），不要指向 worktree 自身目录**：

```bash
export HVIGOR_USER_HOME=/path/to/repo/.workwork/hvigor-home
mkdir -p "$HVIGOR_USER_HOME"
cp -R ~/.hvigor/wrapper "$HVIGOR_USER_HOME"/   # 避免 pnpm 重新拉引擎
```

**坑**：把 `HVIGOR_USER_HOME` 设成 `worktree 内的目录`（如 `$PWD/.hvigor-home`）时，
hvigor 会**把工程级 `music_app/hvigor/hvigor-config.json5` 整个移进该 HOME**，
导致该入库文件从磁盘消失。症状极具误导性：

```
Error Message: Hvigor config file .../music_app/hvigor/hvigor-config.json5 does not exist.
```

而 `git status` **干干净净**——文件明明在 git 树里，却不在磁盘上，容易误判为
git 损坏而去查 `git fsck`/重新 clone。**解法：`git checkout HEAD --
music_app/hvigor/hvigor-config.json5` 恢复，并把 `HVIGOR_USER_HOME` 改到
`.workwork/`**（`.workwork/` 已被 gitignore、按工作树隔离，既是中间产物该待的
地方，也不会被误删入库文件）。
