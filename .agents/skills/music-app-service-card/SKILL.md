---
name: music-app-service-card
description: music_app 桌面服务卡片与趣味特性：2x2/2x4 卡片架构（FormAbility 与主 UIAbility 靠 filesDir JSON 交接）、进度双驱动推送与墙钟锚点、卡片按钮控制通道（message+CommonEvent）、卡片配色限制、麦克风律动、分享歌曲卡片图。触发：改 form/ 下卡片页面或 FormAbility；卡片进度不刷新/按钮无响应；卡片配色或 form_config.json schema；麦克风律动与 FFT；分享卡片截图。
---

# music_app 桌面服务卡片与趣味特性

## 桌面服务卡片（2x2 播放卡片）

- 架构（`form/FormAbility.ets` + `form/pages/MusicCard.ets` + `common/FormStateFile.ets`）：
  FormExtension 与主 UIAbility **不共享内存**，靠应用沙箱 filesDir 下两个 JSON 文件交接——
  `form_state.json`（主进程经 `AppStore.syncFormState` 写入快照，与推送同节奏落盘）、
  `form_ids.json`（卡片实例 id 由 `FormAbility.onAddForm` 从 want 的
  `FormParam.IDENTITY_KEY` 登记、`onRemoveForm` 移除；**系统不提供第三方查询本应用
  卡片 formId 的接口**，必须自己落盘记录）。
- **进度刷新机制**：卡片无法本地走秒、只能靠主进程推送驱动重绘
  （**真机踩坑**：TextTimer 虽官方标注 API 10 起支持卡片，但真机卡片上
  `onTimer` 不触发，"卡片本地走秒"路线已验证不成立；`setInterval` 在
  卡片页面同样不可用）。**现行双驱动**（`AppStore.syncFormState`）：
  ① 状态变化（播控/切歌/seek/失败停止等）即时推送；② 播放中自驱
  `setInterval`（`FORM_PROGRESS_PUSH_MS` 1s，节流窗口=定时器周期；用户
  决策接受每秒推送/写盘的常驻成本）每秒推送——音频长时任务保活下后台
  定时器可靠，不依赖真机后台会停报的 AVPlayer `timeUpdate`（timeUpdate
  仅刷新插值锚点 `formTickBaseAt`，保证停报时快照位置仍准；启停/切歌
  即重锚、位置夹在时长内）。推送载荷带 `anchorAt`（墙钟采样时刻），卡片
  按「锚点+墙钟增量」推算显示位置，推送到达延迟/丢拍时显示仍准。
  seek 是不连续跳变，`PlayerController.seek` 即时 `notifyState` 广播新
  锚点并同步 AVSession 播放态，否则卡片/锁屏从旧锚点外推出错。
  推送载荷必须经 `toCardPayload` 映射（快照键 `coverPath` → 卡片键
  `cover`，直接推原始快照卡片收不到封面，已踩坑）；`FormAbility.buildCardData`
  （加卡/系统拉起时的快照）同用该映射并含进度字段与锚点。
  `updateEnabled: false`（无定时刷新配额消耗），刷新完全靠主动推送；
  秒推节奏可用 `hilog | grep formPush` 核验。
- 卡片按钮控制通道（踩坑史，最终方案 message + CommonEvent）：
  ① call 型 `postCardAction` 在真机+模拟器均不送达（点击零反应、无
  onNewWant 日志，原因未明），弃用；② router 型可用但会把应用拉到前台
  （违背卡片免进应用的本意）；③ **最终：message 型发到 FormAbility
  （`onFormEvent` 解析 `method`），经 `commonEventManager.publish` 转发
  自定义公共事件 `CARD_ACTION_EVENT`，主进程 AppStore 订阅执行播放控制**
  ——完全后台、不拉前台。主进程存活即响应（播放中/暂停都有后台长时任务
  保活）；主进程被杀后点击静默无效（FormExtensionContext 无 startAbility
  无法拉起，点卡片空白 router 进应用即恢复），已知限制。EntryAbility 的
  `handleCardAction`（want.parameters.method）保留：兜底冷启动带参拉起。
- 卡片内**无法引用应用主题资源**（`$r('app.color.*')` 不可用），配色写死对齐
  `dark/element/color.json` 的 viz token；控制图标用自带 SVG（`ic_card_*.svg`），
  勿用 `sys.media.*` 图标名（无法在本机 id_defined.json 核实存在性）。
- form_config.json schema 坑：`isDefault` 必填、`uiSyntax: "arkts"` 必填、
  window 字段名是 `autoDesignWidth`（非 autoDesignWidthScale）。

## 趣味特性（麦克风律动 / 2x4 卡片 / 分享卡片图）

- **麦克风律动**（`common/MicSpectrum.ets` + `common/Fft.ets`）：设置页开关
  （`appStore.setMicLive`）→ AtManager 请求 MICROPHONE（Stage 模型权限入口是
  `abilityAccessCtrl.createAtManager().requestPermissionsFromUser`，
  UIAbilityContext 上的同名方法是 FA 模型遗留不可用）→ AVAudioCapturer
  16k/单声道/S16LE 采集（AudioStreamInfo 的 `encodingType` 必填
  ENCODING_TYPE_RAW）→ 1024 点滑窗 FFT（`Fft.ets` 纯函数 LocalUnit 可测）
  → beat 突增检测 + bass/treble EMA → 就地更新 levels 供 VisualizerView
  帧循环拉取。采集器跟随舞台激活态启停（省电）；环境声无效（~3s 无能量）
  或采集失败（模拟器无麦）自动回退 VisualizerCore 合成。外放才有效，
  耳机场景收不到声是物理限制不是 bug。标定常数（GAIN/RATIO）集中在
  MicSpectrum 顶部，真机校准在此调。
- **2x4 桌面卡片**（`form/pages/MusicCardWide.ets`）：与 2x2 共用
  FormAbility 与 form_state.json（含 positionMs/durationMs/progress/anchorAt）；
  进度刷新机制见「桌面服务卡片」一节（状态变化即时推送 + 播放中每秒
  自驱推送、墙钟锚点外推）。**两个卡片页面文件的
  顶层 LocalStorage 变量不得同名**（同 ets 编译单元冲突，已踩坑）。
- **分享歌曲卡片图**（PlayerPage 顶栏分享按钮 → bindSheet）：预览卡
  `.id('share_card')` → `componentSnapshot.get` 截图 → SaveButton 安全控件
  onClick 内（临时授权，免申请受限的 WRITE_IMAGEVIDEO）→
  photoAccessHelper.createAsset + image ImagePacker.packToFile 写入相册。
  分享图标 `sys.symbol.arrow_up_and_rectangle_on_rectangle`（id_defined.json
  已核实；`sys.symbol.share` 不存在）。
- @Trace 跨单例镜像仍走 stateListener 管道：AppStore 设置项变更后调
  `player.notifyPrefs()`（public 转发私有 notifyState('prefs')），各页面
  在既有订阅回调里刷新 @Local 镜像（如 micOn）。
