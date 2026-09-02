/**
 * EQ 均衡器播放指示器（Poweramp 标志性元素）：
 * 三根小柱随播放跳动，暂停时静止。用于列表当前行与队列当前行，
 * 替代静态播放/暂停图标。
 */
@ComponentV2
export struct EqIndicator {
  /** 是否处于播放态（true 跳动 / false 静止） */
  @Param active: boolean = true;
  @Param color: Resource = $r('app.color.accent');
  /** 三根柱的当前高度（vp），由定时器驱动、animation 属性平滑过渡 */
  @Local heights: number[] = [10, 16, 7];
  private timerId: number = -1;

  aboutToAppear(): void {
    if (this.active) {
      this.start();
    }
  }

  aboutToDisappear(): void {
    this.stop();
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
    if (this.timerId >= 0) {
      return;
    }
    this.timerId = setInterval(() => {
      this.tick();
    }, 320);
  }

  private stop(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /** 各柱独立相位随机高度，营造均衡器律动 */
  private tick(): void {
    const next: number[] = [];
    for (let i = 0; i < this.heights.length; i++) {
      const min = 3 + i * 2;
      next.push(min + Math.random() * (17 - i * 3));
    }
    this.heights = next;
  }

  build() {
    Row({ space: 2 }) {
      ForEach(this.heights, (h: number, index: number) => {
        Column()
          .width(2.5)
          .height(h)
          .borderRadius(1.25)
          .backgroundColor(this.color)
          .animation({ duration: 300, curve: Curve.EaseInOut })
      }, (h: number, index: number) => `${index}_${h}`)
    }
    .height(20)
    .alignItems(VerticalAlign.Center)
  }
}
