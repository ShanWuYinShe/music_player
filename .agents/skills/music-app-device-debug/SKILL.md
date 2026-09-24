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
