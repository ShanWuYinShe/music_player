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
    Column({ space: 16 }) {
      // 在线音乐源
      Column({ space: 10 }) {
        Text('在线音乐源')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('填入音乐 API 服务地址，下期版本接入在线搜索与播放。')
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
          .height(40)
          .fontSize(15)
          .borderRadius(20)
          .backgroundColor($r('sys.color.font_primary'))
          .onClick(() => {
            appStore.saveOnlineBaseUrl(this.baseUrl.trim());
            promptAction.showToast({ message: '已保存' });
          })
      }
      .width('100%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor($r('sys.color.background_secondary'))
      .alignItems(HorizontalAlign.Start)

      // 关于
      Row({ space: 14 }) {
        Image($r('app.media.app_icon'))
          .width(52)
          .height(52)
          .borderRadius(12)
        Column({ space: 4 }) {
          Text('音乐播放器')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Text('v1.0.0 · 本地导入 · 后台播放 · 锁屏控制')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor($r('sys.color.background_secondary'))

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor($r('sys.color.background_primary'))
  }
}
