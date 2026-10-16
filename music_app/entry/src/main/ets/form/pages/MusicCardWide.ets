import { firstGlyph } from '../../common/TextFormat';
import { extrapolateDisplayPosition } from '../../common/FormExtrapolate';
import { cardPlayAction } from '../CardActions';

let cardStorageWide = new LocalStorage();

/**
 * 2x4 桌面播放卡片（宽规格，与 2x2 的 MusicCard 共用 FormAbility 与数据）：
 * 左封面 + 中部歌名/歌手/进度条 + 右侧控制按钮列。进度由主进程推送驱动
 * 重绘：状态变化（播控/切歌/seek）即时推送 + 播放中每秒推送一次；卡片按
 * 「锚点 positionMs + 墙钟增量（now - anchorAt）」推算显示位置，推送到达
 * 延迟或丢一拍时显示仍准（下一拍自愈）。真机踩坑：TextTimer 在卡片上
 * onTimer 不触发、卡片无法本地走秒，只能靠推送驱动重绘。
 */
@Entry(cardStorageWide)
@Component
struct MusicCardWide {
  @LocalStorageProp('title') title: string = '';
  @LocalStorageProp('artist') artist: string = '';
  @LocalStorageProp('cover') cover: string = '';
  @LocalStorageProp('playing') playing: boolean = false;
  @LocalStorageProp('positionMs') positionMs: number = 0;
  @LocalStorageProp('durationMs') durationMs: number = 0;
  @LocalStorageProp('progress') progress: number = 0;
  @LocalStorageProp('anchorAt') anchorAt: number = 0;

  /** 控制按钮统一走 form/CardActions 的 cardPlayAction */
  /** ms → m:ss（卡片内独立小函数，不引公共库） */
  private fmt(ms: number): string {
    const total = Math.floor(ms / 1000);
    const m = Math.floor(total / 60);
    const s = total % 60;
    return `${m}:${s < 10 ? '0' : ''}${s}`;
  }

  /** 显示位置（ms）：锚点 + 墙钟增量，夹在时长内。每次推送更新
   * LocalStorageProp 后 build 重算，推送间隙的到达延迟由增量补齐。
   * 规则与主进程侧共用 FormExtrapolate.extrapolateDisplayPosition——两端
   * 算法逐字一致，否则同一时刻主进程与卡片显示不同进度 */
  private dispMs(): number {
    if (!this.playing) {
      return this.positionMs;
    }
    return extrapolateDisplayPosition(this.positionMs, this.anchorAt,
      Date.now(), this.durationMs);
  }

  build() {
    Row() {
      if (this.cover !== '') {
        Image(this.cover)
          .width('30%')
          .aspectRatio(1)
          .borderRadius(14)
          .objectFit(ImageFit.Cover)
      } else {
        Stack() {
          Text(this.title !== '' ? firstGlyph(this.title) : '音')
            .fontSize(40)
            .fontWeight(FontWeight.Bold)
            .fontColor('#8E8878')
        }
        .width('30%')
        .aspectRatio(1)
        .borderRadius(14)
        .backgroundColor('#2A2823')
      }

      Column() {
        Text(this.title !== '' ? this.title : '未在播放')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.title !== '' ? '#F3EFE4' : '#8E8878')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.artist)
          .fontSize(13)
          .fontColor('#C6C0B0')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
          .width('100%')

        // 进度条：发丝底轨 + 朱砂进度线（主进程每秒推送驱动重绘）
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(3)
            .borderRadius(1.5)
            .backgroundColor('#464135')
          Row()
            .width(`${Math.max(0, Math.min(1, this.dispMs() / (this.durationMs > 0 ? this.durationMs : 1))) * 100}%`)
            .height(3)
            .borderRadius(1.5)
            .backgroundColor('#D96C45')
        }
        .width('100%')
        .margin({ top: 12 })

        Row() {
          Text(this.fmt(this.dispMs()))
            .fontSize(10)
            .fontColor('#8E8878')
          Blank()
          Text(this.fmt(this.durationMs))
            .fontSize(10)
            .fontColor('#8E8878')
        }
        .width('100%')
        .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 14, right: 10 })

      Column({ space: 10 }) {
        Image(this.playing ? $r('app.media.ic_card_pause') : $r('app.media.ic_card_play'))
          .width(34)
          .height(34)
          .accessibilityText(this.playing ? '暂停' : '播放')
          .padding(4)
          .onClick(() => cardPlayAction(this, 'toggle'))
          .responseRegion({ x: -3, y: -3, width: 40, height: 40 })
        Row({ space: 16 }) {
          // 24px 图标命中区扩到 40vp(触控热区下限),视觉零变化
          Image($r('app.media.ic_card_prev'))
            .width(24)
            .height(24)
            .accessibilityText('上一首')
            .padding(3)
            .onClick(() => cardPlayAction(this, 'previous'))
            .responseRegion({ x: -8, y: -8, width: 40, height: 40 })
          Image($r('app.media.ic_card_next'))
            .width(24)
            .height(24)
            .accessibilityText('下一首')
            .padding(3)
            .onClick(() => cardPlayAction(this, 'next'))
            .responseRegion({ x: -8, y: -8, width: 40, height: 40 })
        }
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    // 铺满卡片窗口：内容自适应高度不足时露出系统白底（实机截图发现）
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(14)
    .backgroundColor('#1E1C19')
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility'
      });
    })
  }
}
