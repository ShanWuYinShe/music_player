---
name: music-app-device-debug
description: music_app 真机/模拟器调试的项目专属部分：包名与入口、一键签名构建安装脚本 tools/auto_sign.sh 的用法与前提、安装后存活与界面验证命令、沙盒缓存重定向。触发：把 music_app 装到真机或模拟器；auto_sign.sh 失败或签名材料/证书过期；安装后启动白屏或进程不在；用 hdc 验证 music_app 界面。
---

# music_app 真机调试（项目专属部分）

**hdc 通用流程（设备自动发现、无线调试连接、tconn 陷阱与僵尸连接清场、uitest 布局与截图验证、沙盒缓存重定向）见用户级 skill `harmony-device-debug`，本文件不复述。**

## 项目事实

- 包名：`com.lsyb.musicplayer`，入口 `EntryAbility`
- 一键签名构建安装：仓库根 `tools/auto_sign.sh`
  - 不带参数 = 只构建；`install` = 构建 + 安装 + 启动
  - 它自己会校验签名材料、profile 有效期、设备绑定；失败会打印去 IDE 重签名的指引
- `compatibleSdkVersion`/`targetSdkVersion` 为 `6.0.0(20)`；自动签名由华为账号绑定前缀决定

## 本项目验证命令

- **存活**：`hdc shell "pidof com.lsyb.musicplayer; bm dump -n com.lsyb.musicplayer" | head`
- **UI**：`hdc shell uitest dumpLayout` 取布局树（应用 root 在 `children[0]`，`children` 为空 = 白屏未渲染）；`hdc shell uinput -T -c <x> <y>` 点击；截图后 read_image 查看

## 本项目的构建注意事项

- 构建必须先起模拟器或连上真机（签名/安装阶段需要设备）
- UI 相关改动在真机上验证时，注意 V2 状态不驱动渲染的已知坑（见 skill `music-app-platform-ui`）——**界面没更新不一定是没装上**
- 手机息屏会断开无线调试：重连成功后立刻跑安装，并提醒用户装机期间别锁屏

## 本地单测（isLocalTest）要求 PATH 含 /usr/sbin（2026-10-12 实测）

`hvigorw ... -p isLocalTest=true test` 会在 `GenerateUnitTestResult` 任务里
调 `@ohos/coverage` 的 `findPort` 探测本地测试端口，**内部依赖 `netstat`/`lsof`**——
macOS 上这两个在 **`/usr/sbin`**。

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

## worktree 内构建（2026-10-14 起无需重定向 hvigor 缓存）

**worktree 无 `oh_modules`/`.hvigor`（均被 gitignore），先 `ohpm install`。**
`~/.hvigor`、`~/.ohpm` 已由 DSH sandbox-extra-roots 放行（2026-10-14 实测），沙盒内直接构建即可；
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
