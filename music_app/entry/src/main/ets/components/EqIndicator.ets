/**
 * EQ 均衡器播放指示器（Poweramp 标志性元素）：
 * 三根小柱随播放跳动，暂停时静止。用于列表当前行与队列当前行，
 * 替代静态播放/暂停图标。
 *
 * 平滑驱动（替代早期 320ms setInterval 跳步）：displaySync 每帧以
 * synthSpectrum 取各柱独立频段能量——与可视化/迷你条同源的确定性
 * 合成，柱间相位错开、逐帧连续，无定时器跳变；暂停即停帧定格。
 */
import displaySync from '@ohos.graphics.displaySync';
import { seedFromId, synthSpectrum } from '../common/VisualizerCore';

@ComponentV2
export struct EqIndicator {
  /** 是否处于播放态（true 跳动 / false 静止） */
  @Param active: boolean = true;
  @Param color: Resource = $r('app.color.accent');
  /** 曲目 id：频谱合成种子（同曲恒定、跨曲变化） */
  @Param songId: string = '';
  /** 三根柱当前高度（vp）：displaySync 帧回调直接赋值（无补间动画） */
  @Local h0: number = 10;
  @Local h1: number = 16;
  @Local h2: number = 7;
  private ds: displaySync.DisplaySync | null = null;
  private running = false;
  private playClock = 0;
  private lastNow = 0;

  aboutToAppear(): void {
    this.ds = displaySync.create();
    const range: ExpectedFrameRateRange = { min: 0, max: 30, expected: 30 };
    this.ds.setExpectedFrameRateRange(range);
    this.ds.on('frame', () => this.frame());
    if (this.active) {
      this.start();
    }
  }

  aboutToDisappear(): void {
    this.stop();
    this.ds = null;
  }

  @Monitor('active')
  onActiveChange(): void {
    if (this.active) {
      this.start();
    } else {
      this.stop();
    }
  }

  private start(): void {
    if (this.running || this.ds === null) {
      return;
    }
    this.running = true;
    this.lastNow = Date.now();
    this.ds.start();
  }

  private stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    if (this.ds !== null) {
      this.ds.stop();
    }
  }

  /** 每帧：柱 i 取频段 (i*3)（三柱频段不相邻、错落独立），能量映射
   * 4..19vp；频谱本身逐帧连续，无需补间动画 */
  private frame(): void {
    if (!this.running) {
      return;
    }
    const now = Date.now();
    const dt = Math.min(now - this.lastNow, 66);
    this.lastNow = now;
    this.playClock += dt;
    const bars = synthSpectrum(seedFromId(this.songId), this.playClock, 9);
    this.h0 = 4 + bars[0] * 15;
    this.h1 = 4 + bars[3] * 15;
    this.h2 = 4 + bars[6] * 15;
  }

  build() {
    Row({ space: 2 }) {
      Column()
        .width(2.5)
        .height(this.h0)
        .borderRadius(1.25)
        .backgroundColor(this.color)
      Column()
        .width(2.5)
        .height(this.h1)
        .borderRadius(1.25)
        .backgroundColor(this.color)
      Column()
        .width(2.5)
        .height(this.h2)
        .borderRadius(1.25)
        .backgroundColor(this.color)
    }
    .height(20)
    .alignItems(VerticalAlign.Center)
  }
}
