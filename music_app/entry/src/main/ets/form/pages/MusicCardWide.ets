let cardStorageWide = new LocalStorage();

/**
 * 2x4 桌面播放卡片（宽规格，与 2x2 的 MusicCard 共用 FormAbility 与数据）：
 * 左封面 + 中部歌名/歌手/进度条 + 右侧控制按钮列。进度由主进程秒针
 * 节流推送（FORM_PROGRESS_PUSH_MS，卡片上是快照进度而非实时）。
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

  private callAction(method: string): void {
    postCardAction(this, {
      action: 'call',
      abilityName: 'EntryAbility',
      params: { method: method }
    });
  }

  /** ms → m:ss（卡片内独立小函数，不引公共库） */
  private fmt(ms: number): string {
    const total = Math.floor(ms / 1000);
    const m = Math.floor(total / 60);
    const s = total % 60;
    return `${m}:${s < 10 ? '0' : ''}${s}`;
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
          Text(this.title !== '' ? this.title.substring(0, 1) : '♪')
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

        // 进度条：发丝底轨 + 金色进度线（快照精度，主进程 15s 节流推送）
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(3)
            .borderRadius(1.5)
            .backgroundColor('#464135')
          Row()
            .width(`${Math.max(0, Math.min(1, this.progress)) * 100}%`)
            .height(3)
            .borderRadius(1.5)
            .backgroundColor('#DBA84E')
        }
        .width('100%')
        .margin({ top: 12 })

        Row() {
          Text(this.fmt(this.positionMs))
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
          .padding(4)
          .onClick(() => this.callAction('toggle'))
        Row({ space: 16 }) {
          Image($r('app.media.ic_card_prev'))
            .width(24)
            .height(24)
            .padding(3)
            .onClick(() => this.callAction('previous'))
          Image($r('app.media.ic_card_next'))
            .width(24)
            .height(24)
            .padding(3)
            .onClick(() => this.callAction('next'))
        }
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .justifyContent(FlexAlign.Center)
    .padding(14)
    .backgroundColor('#1D1C1A')
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility'
      });
    })
  }
}
