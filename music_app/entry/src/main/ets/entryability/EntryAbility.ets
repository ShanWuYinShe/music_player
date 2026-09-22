import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { appStore } from '../viewmodel/AppStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
    appStore.init(this.context)
      .then(() => {
        // 冷启动携带的卡片控制指令须等播放器就绪后执行
        this.handleCardAction(want);
      })
      .catch((err: Object) => {
        hilog.error(DOMAIN, TAG, 'appStore init failed: %{public}s', JSON.stringify(err));
      });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onNewWant');
    this.handleCardAction(want);
  }

  /**
   * 桌面卡片按钮的 call 指令（postCardAction params.method）：后台执行
   * 播放控制，不拉起前台界面。未知/缺失参数静默忽略。
   */
  private handleCardAction(want: Want): void {
    const params = want.parameters;
    if (!params) {
      return;
    }
    appStore.dispatchCardAction(String(params['method']));
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
    appStore.disposeCardBridge();
    appStore.persistAll();
    appStore.player.destroy();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageCreate');
    this.setupImmersiveWindow(windowStage);
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      // 避让区高度须在页面加载完成后读取：窗口刚创建时 avoid area 尚未
      // 就绪（实测读到 0）。@Trace 字段赋值后已渲染的页面自动刷新。
      appStore.readSafeArea();
      hilog.info(DOMAIN, TAG, 'Succeeded in loading content.');
    });
  }

  /**
   * 全局恒定全屏布局：启动即开启且此后任何页面不得关闭。
   * - 画面要真正延伸到系统栏下只能靠它（组件级 expandSafeArea 无法让
   *   Canvas 画进系统栏区域，系统栏会露出 window 固定兜底色，与画面
   *   动态颜色割裂，真机踩坑）；
   * - 页面级开关全屏布局会因异步恢复滞后导致返回首页时布局跳动（已踩坑），
   *   因此窗口模式恒定，各页面统一用 safeTopVp/safeBottomVp 自行避让。
   */
  private setupImmersiveWindow(windowStage: window.WindowStage): void {
    try {
      const win = windowStage.getMainWindowSync();
      // 全屏布局恒定开启；窗口兜底色与系统栏字色随系统深浅模式自适应
      // （深浅色板切换由资源限定符完成，见 base|dark/element/color.json）
      win.setWindowLayoutFullScreen(true);
      appStore.applyWindowChrome();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setup immersive window failed: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
  }
}
