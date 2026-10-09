import { firstGlyph } from '../../common/TextFormat';
import { cardPlayAction } from '../CardActions';

let cardStorage = new LocalStorage();

/**
 * 2x2 桌面播放卡片（ArkTS 卡片范式）：
 * - 数据经 FormBindingData 注入 LocalStorage（键与 FormAbility.buildCardData 对应）；
 * - 按钮用 call 型 postCardAction 后台拉起 EntryAbility 执行播放控制，不进前台；
 * - 恒定深色舞台配色（媒体卡片惯例，与播放页 viz token 一致，卡片资源
 *   无法引用应用主题，色值写死对齐 dark/element/color.json）。
 */
@Entry(cardStorage)
@Component
struct MusicCard {
  @LocalStorageProp('title') title: string = '';
  @LocalStorageProp('artist') artist: string = '';
  @LocalStorageProp('cover') cover: string = '';
  @LocalStorageProp('playing') playing: boolean = false;

  /** 控制按钮统一走 form/CardActions 的 cardPlayAction */
  build() {
    Column() {
      Row() {
        if (this.cover !== '') {
          Image(this.cover)
            .width('44%')
            .aspectRatio(1)
            .borderRadius(16)
            .objectFit(ImageFit.Cover)
        } else {
          Stack() {
            Text(this.title !== '' ? firstGlyph(this.title) : '音')
              .fontSize(44)
              .fontWeight(FontWeight.Bold)
              .fontColor('#8E8878')
          }
          .width('44%')
          .aspectRatio(1)
          .borderRadius(16)
          .backgroundColor('#2A2823')
        }

        Column() {
          Text(this.title !== '' ? this.title : '未在播放')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.title !== '' ? '#F3EFE4' : '#8E8878')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.title !== '') {
            Text(this.artist)
              .fontSize(13)
              .fontColor('#C6C0B0')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 5 })
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 14 })
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)
      .width('100%')

      Row({ space: 8 }) {
        // 2x2 卡片空间紧,不放图形尺寸:用 responseRegion 把 26px 图标的
        // 命中区扩到 40vp(触控热区下限),视觉零变化
        Image($r('app.media.ic_card_prev'))
          .width(26)
          .height(26)
          .onClick(() => cardPlayAction(this, 'previous'))
          .padding(4)
          .responseRegion({ x: -7, y: -7, width: 40, height: 40 })
        Image(this.playing ? $r('app.media.ic_card_pause') : $r('app.media.ic_card_play'))
          .width(40)
          .height(40)
          .onClick(() => cardPlayAction(this, 'toggle'))
          .padding(4)
        Image($r('app.media.ic_card_next'))
          .width(26)
          .height(26)
          .onClick(() => cardPlayAction(this, 'next'))
          .padding(4)
          .responseRegion({ x: -7, y: -7, width: 40, height: 40 })
      }
      .justifyContent(FlexAlign.Center)
      .height(48)
      .width('100%')
      .margin({ bottom: 6 })
    }
    .justifyContent(FlexAlign.Center)
    .padding(14)
    .backgroundColor('#1E1C19')
    .backgroundImageSize(ImageSize.Cover)
    .onClick(() => {
      // 卡片空白处点击进应用（控制按钮自身的 onClick 会拦截，不冒泡到这里）
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility'
      });
    })
  }
}
