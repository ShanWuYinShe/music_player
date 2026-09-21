# music_app（HarmonyOS 音乐播放器）

本目录是 HarmonyOS 应用工程（ArkTS + ArkUI，Stage 模型），仓库级结构与服务端
说明见上级 [AGENTS.md](../AGENTS.md)。以下命令均在本目录（music_app/）内执行。

本工程约定按主题拆分为 skill（见文末索引），**改对应模块前先加载对应 skill**；
本文件只保留每次都需要的要点与红线，避免撑爆工作区指令预算（超预算会导致整份文件被丢弃）。

## 架构要点（速记）

- 零第三方运行时依赖（仅 devDependencies @ohos/hypium），全部使用系统能力。
- `module.json5` 必须含 `"pages": "$profile:main_pages"`：缺失时构建不报错，但运行时 loadContent 返回 401 白屏（已踩坑）。
- 播放内核 AVPlayer（每次切歌重建实例 + 代际号废弃旧回调）；媒体会话 AVSession。
- 状态管理统一 V2 体系（@ObservedV2/@Trace + @ComponentV2/@Param/@Local）。
- **真机渲染红线**：全局单例的 @Trace 对 if 分支条件与属性插值不触发 UI 更新，
  渲染层必须走 `addStateListener/removeStateListener` 多播订阅 + @Local 镜像。
- 播放页舞台双态互斥（封面模式 / 可视化模式），不要恢复旧设计。
- 在线源 OnlineSource 走 SWR 缓存（默认视图持久化到 filesDir）。
- 收藏/最近播放跨源融合：在线歌元数据注册表（`OnlineSongStore`，filesDir/online_songs.json）持久化，首页一级签「曲库/喜欢/最近/在线」中喜欢/最近为跨源混排视图，收藏的在线歌钉住整曲缓存不被 LRU 淘汰。

> 以上每条的完整原因、踩坑记录与其余细则见 skill `music-app-platform-ui`。

## 本地命令

构建/测试/lint/模拟器命令见 README.md「构建与运行」；要点：

- hvigor/ohpm/node 均用 DevEco 内置：`/Applications/DevEco-Studio.app/Contents/tools/...`
- hvigorw 打包需 `JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home`（仅 hvigor 命令需要）且 `DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk`（本机 26.0.0）
- 模拟器 CLI：`/Applications/DevEco-Studio.app/Contents/tools/emulator/Emulator -list|-start <name>|-stop <name>`
- hdc：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`
- 模拟器可安装未签名 HAP，但运行时页面白屏；已配置 DevEco 自动签名（build-profile.json5 的 signingConfigs，密码为本机加密串，仅本机可用），命令行构建自动产出 `entry-default-signed.hap`
- **一键签名构建安装**：`tools/auto_sign.sh`（仓库根下）——校验签名材料存在/有效期/设备绑定后，命令行构建 signed HAP，`install` 参数再安装+启动到已连接设备；签名材料（`~/.ohos/config/default_music_app_*.p12/.cer/.p7b`）由 DevEco 自动签名生成、有效期一年，材料有效期内全程无需打开 IDE；材料缺失/过期/新设备未绑定时脚本会打印指引，只需去 IDE 点一次「Automatically generate signature」重新生成；签名材料是否存在以 `tools/auto_sign.sh` 的校验结果为准（2026-09 曾核实本机材料缺失过一轮，勿凭本记录断定现状）
- UI 自动化验证：`hdc shell uitest dumpLayout` 取 UI 树（应用 root 在 children[0]，检查 children 是否为空判断页面是否渲染）、`hdc shell uinput -T -c <x> <y>` 模拟点击、`snapshot_display` 截图

## 约束

- 系统资源引用（`sys.symbol.*`/`sys.color.*`）先在 `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/id_defined.json` 中核实名称存在性再用
- rawfile 演示曲目文件名约定 `demoXX_歌手 - 歌名.wav`，由 `MusicLibrary.fillFromFileName` 解析；重新生成见 git 历史（python3 合成脚本）

## 主题索引（按需加载 skill）

| skill | 何时加载 |
|---|---|
| `music-app-platform-ui` | 改 ArkTS 页面/组件、播放内核、媒体会话、主题与颜色资源、播放页手势与舞台、在线源与缓存、排查真机渲染不更新或白屏 |
| `music-app-shader-pipeline` | 改 `entry/src/main/cpp/shaders` 下 GLSL、增删可视化场景、调帧驱动/displaySync、接入传感器体感、排查可视化黑屏/闪烁/掉帧、改 shader_playground |
| `music-app-service-card` | 改 `form/` 下卡片页面或 FormAbility、卡片进度不刷新或按钮无响应、卡片配色与 form_config.json、麦克风律动、分享卡片图 |

> 新增主题优先建 skill 并在此登记，不要继续往本文件堆长内容。
