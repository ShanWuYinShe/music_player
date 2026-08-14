import { promptAction } from '@kit.ArkUI';
import { appStore } from '../viewmodel/AppStore';

/**
 * 设置页：在线音乐源配置（本期预留）与应用信息
 */
@ComponentV2
export struct SettingsPage {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Local baseUrl: string = appStore.onlineSource.baseUrl;

  build() {
    Column({ space: 12 }) {
      Column({ space: 8 }) {
        Text('在线音乐源')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('预留配置项：填入音乐 API 服务地址（如 NeteaseCloudMusicApi），下期版本接入在线搜索与播放。')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
        TextInput({ text: this.baseUrl, placeholder: 'https://example.com:3000' })
          .width('100%')
          .fontSize(14)
          .backgroundColor($r('sys.color.background_tertiary'))
          .onChange((value: string) => {
            this.baseUrl = value;
          })
        Button('保存')
          .width('100%')
          .backgroundColor($r('sys.color.font_primary'))
          .onClick(() => {
            appStore.saveOnlineBaseUrl(this.baseUrl.trim());
            promptAction.showToast({ message: '已保存' });
          })
      }
      .width('100%')
      .padding(16)
      .borderRadius(16)
      .backgroundColor($r('sys.color.background_secondary'))
      .alignItems(HorizontalAlign.Start)

      Column({ space: 8 }) {
        Text('关于')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('音乐播放器 v1.0.0\n本地导入 · 后台播放 · 锁屏控制')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .padding(16)
      .borderRadius(16)
      .backgroundColor($r('sys.color.background_secondary'))
      .alignItems(HorizontalAlign.Start)

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor($r('sys.color.background_primary'))
  }
}
