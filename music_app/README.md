# 音乐播放器（HarmonyOS）

基于 ArkTS + ArkUI（Stage 模型）的 HarmonyOS 音乐播放器应用，零第三方依赖，全部使用系统能力实现。

## 功能

- **本地音乐导入**：通过系统音频选择器（`AudioViewPicker`）批量导入设备音频（mp3/wav/flac/m4a/aac/ogg），复制入应用沙盒并建立曲库索引
- **元数据解析**：mp3 自动读取 ID3v2 标签（歌名/歌手/专辑/封面），其余格式按「歌手 - 歌名」文件名解析
- **完整播放控制**：播放/暂停/上一首/下一首、进度条拖拽、三种播放模式（顺序/单曲循环/随机）
- **曲库管理**：搜索（歌名/歌手）、分类（全部/喜欢/最近播放）、四种排序、长按菜单、左滑「下一首播放/删除」
- **喜欢与最近播放**：收藏歌曲、自动记录最近播放，均本地持久化
- **播放增强**：音量调节（含静音）、定时关闭（15/30/60 分钟）、插播队列、退出续播（记住上次曲目与进度）
- **播放队列**：播放页半模态队列视图，展示插播标记，点按即切歌
- **后台播放**：`audioPlayback` 长驻任务，退到后台持续播放
- **媒体控制**：AVSession 接入系统媒体中心，支持通知栏与锁屏播控（播放/暂停/切歌/进度）
- **演示曲目**：内置 3 段合成演示音频，「载入演示曲目」一键入库，开箱可听
- **在线音乐**：首页「本地 / 在线」源切换；默认对接线上服务（`https://yinghuoren.com/api/music`，设置页可改、留空用默认）。在线列表来自服务器曲库，搜索由服务端完成并聚合网易云网络源（输入停顿自动触发），流式播放支持 HTTP Range（AVPlayer 网络直连）
- **深浅色**：全部颜色使用系统分层资源，自动跟随系统深浅色模式

## 工程结构

```
AppScope/                          应用级配置与资源
build-profile.json5                工程构建配置（签名/SDK 版本）
hvigor/hvigor-config.json5         hvigor 版本配置
entry/src/main/
├── module.json5                   模块配置（后台模式、权限声明）
├── ets/
│   ├── entryability/              UIAbility 入口
│   ├── pages/                     Index(首页)/PlayerPage(播放页)/SettingsPage(设置页)
│   ├── components/                SongItem、MiniPlayerBar、MenuItemRow
│   ├── player/                    PlayerController(AVPlayer内核)、SessionController(媒体会话)
│   ├── library/                   MusicLibrary(曲库)、Id3Parser(ID3v2解析)
│   ├── source/                    MusicSource 抽象、OnlineApi(在线响应解析)
│   ├── viewmodel/                 AppStore 全局状态、UserData(喜欢/最近播放)
│   ├── model/                     Song、PlayMode
│   └── common/                    TimeUtils、LibraryFilter(筛选排序纯逻辑)
├── resources/                     base/dark/zh_CN 资源 + rawfile 演示音频
└── src/test/                      本地单元测试（hypium LocalUnit）
```

## 构建与运行

命令行构建（工具链为本机 DevEco Studio 自带）：

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export JAVA_HOME="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home"
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin:$PATH"

ohpm install
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
# 产物：entry/build/default/outputs/default/entry-default-unsigned.hap
```

本地单元测试：

```bash
hvigorw --mode module -p module=entry@default -p isLocalTest=true test --no-daemon
# 结果：entry/.test/default/intermediates/test/coverage_data/test_result.txt
```

静态检查：

```bash
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/plugins/codelinter/run/index.js -e error
```

模拟器运行（DevEco Studio）：

1. 用 DevEco Studio 打开工程
2. File > Project Structure > Signing Configs 勾选 **Automatically generate signature** 完成自动签名（已配置，bundleName 为 `com.lsyb.musicplayer`）
3. 选择模拟器点击 Run；命令行方式见下

> 注意：模拟器允许 `hdc install` 未签名 HAP，但**运行时页面加载要求签名**（未签名会白屏），
> 因此真机/模拟器运行前必须完成签名步骤。

命令行安装运行（模拟器已启动时）：

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC shell aa start -a EntryAbility -b com.lsyb.musicplayer
```

**一键签名构建+安装**（推荐，签名有效期内无需打开 IDE）：

```bash
# 以下命令均须在仓库根（music_player/）执行，脚本按自身位置解析仓库根
tools/auto_sign.sh          # 校验签名材料并构建 signed HAP
tools/auto_sign.sh install  # 校验 + 构建 + 安装 + 启动到已连接设备
```

签名材料（`~/.ohos/config/default_music_app_*.p12/.cer/.p7b`）由 DevEco 自动签名
生成（File > Project Structure > Signing Configs 勾选 "Automatically generate
signature"，需登录华为账号），debug profile 有效期一年。有效期内命令行直接构建；
材料缺失/过期/新设备未绑定时，脚本会打印指引，只需去 IDE 重新生成一次签名。

> 签名材料含私钥且绑定设备 UDID，**不入库**（build-profile.json5 的 material 为
> 本机绝对路径，DevEco 每次重新生成会自动改写该段）。

> 当前签名 HAP 仅本地安装（`hdc install` 到已连接的模拟器/真机），未建立应用内更新通道。

## 音乐导入说明

HarmonyOS（API 24）已移除 `READ_MEDIA_AUDIO` 权限，应用无法静默扫描公共媒体库。
本地音乐的标准获取方式是系统音频选择器（用户主动选择、免权限弹窗），选择后文件被复制到应用沙盒
`files/music/`，索引持久化于 `files/library.json`。

## 后续计划

- 在线源升级：在线歌单、喜欢/最近跨源聚合（服务端关键词搜索 `/songs?q=` 已实现）
- 歌词显示、桌面卡片、自建歌单
