import { promptAction } from '@kit.ArkUI';
import { appStore } from '../viewmodel/AppStore';
import { formatTotalDuration } from '../common/TimeUtils';
import { DEFAULT_ONLINE_BASE_URL } from '../source/OnlineApi';

/**
 * 设置页：曲库统计 / 在线音乐源配置 / 危险操作 / 应用信息
 */
@ComponentV2
export struct SettingsPage {
  @Param navPathStack: NavPathStack = new NavPathStack();
  /** 地址输入的本地草稿：失焦/离开页面时统一持久化 */
  @Local urlInput: string = appStore.onlineSource.configuredUrl;

  aboutToDisappear(): void {
    // 系统返回键不触发输入框失焦，离开页面兜底保存一次（值未变则内部早退）
    appStore.saveOnlineBaseUrl(this.urlInput);
  }

  build() {
    Stack() {
      // 全屏背景层：延伸至状态栏与导航条下方
      Column()
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
        .justifyContent(FlexAlign.Center)
        .onClick(() => this.navPathStack.pop())

        Text('设置')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ink'))
        Blank()
      }
      .width('100%')
      .padding({ top: 4, bottom: 2 })

      // 曲库统计
      Row({ space: 14 }) {
        Column() {
          SymbolGlyph($r('sys.symbol.music_note_list'))
            .fontSize(24)
            .fontColor([$r('app.color.paper')])
        }
        .width(44)
        .height(44)
        .borderRadius(12)
        .backgroundColor($r('app.color.ink'))
        .justifyContent(FlexAlign.Center)

        Column({ space: 3 }) {
          Text('曲库')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
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
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink'))
        Text('music_server 服务地址（含 /api 前缀），留空使用默认服务。')
          .fontSize(12)
          .fontColor($r('app.color.ink_soft'))
        TextInput({ text: this.urlInput, placeholder: DEFAULT_ONLINE_BASE_URL })
          .width('100%')
          .fontSize(14)
          .backgroundColor($r('app.color.surface_alt'))
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
      }
      .width('100%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor($r('app.color.surface'))
      .alignItems(HorizontalAlign.Start)

      // 清空曲库（危险操作）：统计只看本地曲库——在线模式下 player.songs
      // 是在线列表，用它计数会把服务器/网络源歌曲误报成本地文件
      Row({ space: 14 }) {
        Column({ space: 3 }) {
          Text('清空曲库')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.danger'))
          Text(`删除全部 ${appStore.library.getAllSongs().length} 首歌曲的文件与记录，同时清空喜欢和播放记录，不可恢复。`)
            .fontSize(12)
            .fontColor($r('app.color.ink_soft'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button('清空')
          .height(34)
          .fontSize(13)
          .borderRadius(17)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .backgroundColor($r('app.color.surface_alt'))
          .fontColor($r('app.color.danger'))
          .enabled(appStore.library.getAllSongs().length > 0 || appStore.userData.favoriteIds.length > 0)
          .onClick(() => this.confirmClearLibrary())
      }
      .width('100%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor($r('app.color.surface'))
      .alignItems(VerticalAlign.Top)

      // 关于
      Row({ space: 14 }) {
        Column() {
          SymbolGlyph($r('sys.symbol.music_note_list'))
            .fontSize(26)
            .fontColor([$r('app.color.paper')])
        }
        .width(52)
        .height(52)
        .borderRadius(12)
        .backgroundColor($r('app.color.ink'))
        .justifyContent(FlexAlign.Center)
        Column({ space: 4 }) {
          Text('音乐播放器')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ink'))
          Text('v1.1.0 · 收藏 · 最近播放 · 定时关闭 · 锁屏控制')
            .fontSize(12)
            .fontColor($r('app.color.ink_soft'))
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor($r('app.color.surface'))

        Blank()
      }
      .width('100%')
      .height('100%')
      // 全局恒定全屏布局：前景内容按预读避让高度留白（背景层已延伸进系统栏）
      .padding({ left: 16, right: 16,
        top: appStore.safeTopVp + 16, bottom: appStore.safeBottomVp + 16 })
    }
    .width('100%')
    .height('100%')
  }

  private librarySummary(): string {
    // 只统计本地曲库（在线模式下 player.songs 是在线列表，不代表本地文件）
    const songs = appStore.library.getAllSongs();
    if (songs.length === 0) {
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
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: $r('app.color.danger'),
        action: () => {
          appStore.clearLibrary();
          promptAction.showToast({ message: '曲库已清空' });
        }
      }
    });
  }
}
