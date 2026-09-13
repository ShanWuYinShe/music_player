let cardStorageWide = new LocalStorage();

/**
 * 2x4 桌面播放卡片（宽规格，与 2x2 的 MusicCard 共用 FormAbility 与数据）：
 * 左封面 + 中部歌名/歌手/进度条 + 右侧控制按钮列。
 * 能耗模型（与锁屏 AVSession 外推同构）：主进程只在播控/切歌/seek 时推送
 * 一次「位置锚点 positionMs + 采样时刻 anchorAt」，走秒由本卡片本地完成——
 * 隐藏 TextTimer（API 10 起支持卡片）当每秒重绘泵，时间/进度数值由
 * 「锚点 + 墙钟增量」推算（TextTimer 正计时不能设偏移起点，count 仅倒计时
 * 生效）。卡片不可见时 TextTimer 自动停走（系统功耗行为），恢复可见后
 * 按锚点一跳到位，天然自愈；主进程播放期间零周期性工作。
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
  /** 每秒重绘泵（TextTimer onTimer 自增）：数值本身不承载时间 */
  @State private tick: number = 0;
  private timerCtrl: TextTimerController = new TextTimerController();

  aboutToAppear(): void {
    this.timerCtrl.start();
  }

  /** 控制按钮：message 型发指令到 FormAbility（经公共事件转发主进程后台
   * 执行，不拉起应用）。call 型真机不送达、router 型会拉前台，均已踩坑 */
  private callAction(method: string): void {
    postCardAction(this, {
      action: 'message',
      abilityName: 'MusicFormAbility',
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

  /** 本地外推的显示位置（ms）：锚点 + 墙钟增量，夹在时长内。入参 pump
   * 是 tick 的读取点——build 执行期间读取才会建立渲染依赖，TextTimer
   * 每秒自增 tick 触发重算；推送字段变化（新锚点）同样即时重算 */
  private dispMs(pump: number): number {
    if (!this.playing || this.anchorAt <= 0) {
      return this.positionMs;
    }
    const pos = this.positionMs + Math.max(0, Date.now() - this.anchorAt);
    return this.durationMs > 0 && pos > this.durationMs ? this.durationMs : pos;
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

        // 进度条：发丝底轨 + 金色进度线（本地外推进度，每秒自走）
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(3)
            .borderRadius(1.5)
            .backgroundColor('#464135')
          Row()
            .width(`${Math.max(0, Math.min(1, this.dispMs(this.tick) / (this.durationMs > 0 ? this.durationMs : 1))) * 100}%`)
            .height(3)
            .borderRadius(1.5)
            .backgroundColor('#DBA84E')
        }
        .width('100%')
        .margin({ top: 12 })

        Row() {
          Text(this.fmt(this.dispMs(this.tick)))
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

      // 隐藏的秒针泵：TextTimer 在卡片渲染进程内本地走秒（API 10 起支持
      // 卡片），onTimer 自增 tick 驱动上方时间/进度每秒重算。透明 1x1 保
      // 持区域可见（可见性判定基于 onVisibleAreaChange 阈值，与透明度无
      // 关）；组件不可见时系统自动停走，恢复后按锚点一跳到位
      TextTimer({ isCountDown: false, controller: this.timerCtrl })
        .format('mm:ss')
        .onTimer((_utc: number, _elapsed: number) => {
          this.tick += 1;
        })
        .opacity(0)
        .width(1)
        .height(1)

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
