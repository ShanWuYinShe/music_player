import { bundleManager } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { appStore } from '../viewmodel/AppStore';
import { formatTotalDuration } from '../common/TimeUtils';
import { DEFAULT_ONLINE_BASE_URL } from '../source/OnlineApi';
import { dayPhaseOverlay } from '../common/InkMood';

/**
 * 设置页：曲库统计 / 在线音乐源配置 / 危险操作 / 应用信息
 */

@ComponentV2
export struct SettingsPage {
  @Param navPathStack: NavPathStack = new NavPathStack();
  /** 地址输入的本地草稿：失焦/离开页面时统一持久化 */
  @Local urlInput: string = appStore.onlineSource.configuredUrl;
  /** 麦克风律动开关 @Local 镜像：切换经 appStore.setMicLive（权限+采集启动
   * 可能失败回退），以返回值校正 UI */
  @Local micOn: boolean = appStore.micOn;
  /** App 自身版本(bundleManager 读取)与服务端版本(/health 公开端点):
   * 排障时用户可直接报出两端构建版本。serverVersion 初值取上次缓存,
   * 弱网重进不再停留「获取中…」 */
  @Local appVersion: string = '…';
  @Local serverVersion: string = appStore.serverVersionCache || '获取中…';
  /** 本地曲库首数镜像：library 非响应式,清空按钮动作里手动归零刷新 */
  @Local libraryCount: number = appStore.library.getAllSongs().length;

  aboutToAppear(): void {
    // 版本号直接在 BundleInfo 顶层（versionName, since 9）——旧代码读
    // Android 风格的 versionInfo.versionInfo 嵌套，本 SDK 无此字段，
    // 真机一直显示「v未知」（走查发现）
    this.readAppVersion();
    appStore.onlineSource.fetchHealth()
      .then((info) => {
        this.serverVersion = info.version;
        appStore.serverVersionCache = info.version;
      })
      .catch(() => {
        this.serverVersion = appStore.serverVersionCache !== ''
          ? `${appStore.serverVersionCache}（上次缓存）` : '无法获取';
      });
  }

  private readAppVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.appVersion = info.versionName !== '' ? info.versionName : '未知';
    } catch (err) {
      this.appVersion = '未知';
    }
  }

  aboutToDisappear(): void {
    // 系统返回键不触发输入框失焦，离开页面兜底保存一次（值未变则内部早退）
    appStore.saveOnlineBaseUrl(this.urlInput);
  }

  build() {
    Stack() {
      // 全屏背景层：延伸至状态栏与导航条下方。墨晕宣纸全屏底 + 时辰
      // 晨昏罩色同首页（不拦截触摸）
      Column() {
        Image($r('app.media.paper_tex'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .position({ x: 0, y: 0 })
          .hitTestBehavior(HitTestMode.None)
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(dayPhaseOverlay())
          .position({ x: 0, y: 0 })
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column({ space: 16 }) {
      // 页头：返回 + 标题（与首页风格统一，替代系统标题栏）
      Row({ space: 8 }) {
        Column() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(20)
            .fontColor([$r('app.color.ink')])
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor($r('app.color.surface_alt'))
        .accessibilityText('返回')
        .justifyContent(FlexAlign.Center)
        .onClick(() => this.navPathStack.pop())

        Text('设置')
          .fontSize(30)
          .fontColor($r('app.color.ink'))
        Blank()
      }
      .width('100%')
      .padding({ top: 4, bottom: 2 })

      // 曲库统计（图标盒降为素色：页面只留「关于」一处朱砂印）
      Row({ space: 14 }) {
        Column() {
          SymbolGlyph($r('sys.symbol.music_note_list'))
            .fontSize(24)
            .fontColor([$r('app.color.ink_soft')])
        }
        .width(44)
        .height(44)
        .borderRadius(12)
        .backgroundColor($r('app.color.surface_alt'))
        .justifyContent(FlexAlign.Center)

        Column({ space: 3 }) {
          Text('曲库')
            .fontSize(16)
            .fontColor($r('app.color.ink'))
          Text(this.librarySummary())
            .fontSize(12)
            .fontColor($r('app.color.ink_soft'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor($r('app.color.surface'))

      // 在线音乐源
      Column({ space: 10 }) {
        Text('在线音乐源')
          .fontSize(16)
          .fontColor($r('app.color.ink'))
        Text('服务地址（含 /api 前缀），留空使用默认服务。')
          .fontSize(12)
          .fontColor($r('app.color.ink_soft'))
        TextInput({ text: this.urlInput, placeholder: DEFAULT_ONLINE_BASE_URL })
          .width('100%')
          .fontSize(14)
          .backgroundColor($r('app.color.surface_alt'))
          // 文字/占位/光标显式用自适应资源：默认文字色随系统主题走，
          // 浅色模式下会在深色 surface_alt 底上形成深底深字（不可见）
          .fontColor($r('app.color.ink'))
          .placeholderColor($r('app.color.ink_faint'))
          .caretColor($r('app.color.accent'))
          // 输入过程只更新内存，失焦/离开页面才持久化，避免每个按键写盘
          .onChange((value: string) => {
            this.urlInput = value;
          })
          .onBlur(() => {
            appStore.saveOnlineBaseUrl(this.urlInput);
          })
        Text('地址会保存在本机，可随时修改。')
          .fontSize(11)
          .fontColor($r('app.color.ink_faint'))
        // 测试连接与输入框同卡：配完即测，不用上下找底部按钮
        Button('保存并测试连接')
          .width('100%')
          .constraintSize({ minHeight: 42 })
          .fontSize(14)
          .borderRadius(21)
          .margin({ top: 4 })
          .backgroundColor($r('app.color.accent'))
          .fontColor($r('app.color.on_accent'))
          .onClick(() => this.saveAndTest())
      }
      .width('100%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor($r('app.color.surface'))
      .alignItems(HorizontalAlign.Start)

      // 麦克风律动：可视化舞台用环境声真频谱驱动（外放场景有效）
      Row({ space: 14 }) {
        Column({ space: 3 }) {
          Text('麦克风律动')
            .fontSize(15)
            .fontColor($r('app.color.ink'))
          Text('开启后，可视化舞台将跟随外放的真实音乐跳动（需播放外放出声）。')
            .fontSize(12)
            .fontColor($r('app.color.ink_soft'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.micOn })
          // 选中态用主题金：系统默认蓝与整包 accent 割裂（真机走查）
          .selectedColor($r('app.color.accent'))
          .onClick(() => this.toggleMic())
      }
      .width('100%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor($r('app.color.surface'))
      .alignItems(VerticalAlign.Top)

      // 清空曲库（危险操作）：统计只看本地曲库——在线模式下 player.songs
      // 是在线列表，用它计数会把服务器/网络源歌曲误报成本地文件
      Row({ space: 14 }) {
        Column({ space: 3 }) {
          Text('清空曲库')
            .fontSize(15)
            .fontColor($r('app.color.danger'))
          Text(`删除全部 ${this.libraryCount} 首歌曲的文件与记录，同时清空喜欢和播放记录，不可恢复。`)
            .fontSize(12)
            .fontColor($r('app.color.ink_soft'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button('清空')
          // constraintSize 替代固定高度：热区达标（≥40vp），大字体不截断
          .constraintSize({ minHeight: 40 })
          .fontSize(13)
          .borderRadius(20)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .backgroundColor($r('app.color.surface_alt'))
          .fontColor($r('app.color.danger'))
          .enabled(this.libraryCount > 0 || appStore.userData.favoriteIds.length > 0)
          .onClick(() => this.confirmClearLibrary())
      }
      .width('100%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor($r('app.color.surface'))
      .alignItems(VerticalAlign.Top)

      // 关于：朱砂方印「乐」作落款（水墨版式的签名语言）
      Row({ space: 14 }) {
        Column() {
          Text('乐')
            .fontSize(28)
            .fontColor($r('app.color.on_accent'))
        }
        .width(52)
        .height(52)
        .borderRadius(12)
        .backgroundColor($r('app.color.accent'))
        .justifyContent(FlexAlign.Center)
        Column({ space: 4 }) {
          Text('音乐播放器')
            .fontSize(16)
            .fontColor($r('app.color.ink'))
          Text(`v${this.appVersion} · 收藏 · 最近播放 · 定时关闭 · 锁屏控制`)
            .fontSize(12)
            .fontColor($r('app.color.ink_soft'))
          Text(`服务端 ${this.serverVersion}`)
            .fontSize(12)
            .fontColor($r('app.color.ink_soft'))
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor($r('app.color.surface'))
      }
      // 全局恒定全屏布局：前景内容按预读避让高度留白（背景层已延伸进系统栏）
      .padding({ left: 16, right: 16,
        top: appStore.safeTopVp + 16, bottom: appStore.safeBottomVp + 16 })
    }
    .width('100%')
    .height('100%')
  }

  /** 切换麦克风律动：权限弹窗与采集启动都在 appStore.setMicLive，失败
   * （权限被拒/无麦克风）回退并提示；Toggle isOn 以实际结果校正 */
  private async toggleMic(): Promise<void> {
    const target = !this.micOn;
    const ok = await appStore.setMicLive(target);
    this.micOn = ok;
    if (!ok && target) {
      promptAction.showToast({ message: '无法启用麦克风律动（权限或设备不支持）' });
    }
  }

  /** 保存并测试连接：先落盘地址（值未变内部早退），再用轻量 providers 接口
   * 测连——成功/失败都在拇指区即时 toast，不用回首页才知道配错 */
  private async saveAndTest(): Promise<void> {
    appStore.saveOnlineBaseUrl(this.urlInput);
    try {
      await appStore.onlineSource.fetchProviders();
      promptAction.showToast({ message: '服务连接正常' });
    } catch (err) {
      promptAction.showToast({
        message: `连接失败：${err instanceof Error ? err.message : '未知错误'}`
      });
    }
  }

  private librarySummary(): string {
    // 只统计本地曲库（在线模式下 player.songs 是在线列表，不代表本地文件）
    const songs = appStore.library.getAllSongs();
    if (this.libraryCount === 0 || songs.length === 0) {
      return '还没有歌曲，去首页导入吧';
    }
    const total = formatTotalDuration(songs.reduce((sum, song) =>
      sum + (song.duration > 0 ? song.duration : 0), 0));
    return `${songs.length} 首 · ${total}`;
  }

  private confirmClearLibrary(): void {
    const count = appStore.library.getAllSongs().length;
    AlertDialog.show({
      title: '清空曲库',
      message: count > 0 ? `将删除 ${count} 首歌曲及其音频文件，且不可恢复。` : '将清空喜欢与播放记录。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      // 对话框底色默认随系统主题，浅色下与页面深色调割裂；显式用自适应
      // surface + 大圆角与整包卡片风格统一，文字仍由系统按主题取色
      backgroundColor: $r('app.color.surface'),
      cornerRadius: 24,
      primaryButton: {
        value: '取消',
        fontColor: $r('app.color.ink_soft'),
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: $r('app.color.danger'),
        action: () => {
          appStore.clearLibrary();
          this.libraryCount = 0; // 统计卡/危险区计数同步归零（library 非响应式）
          promptAction.showToast({ message: '曲库已清空' });
        }
      }
    });
  }
}
