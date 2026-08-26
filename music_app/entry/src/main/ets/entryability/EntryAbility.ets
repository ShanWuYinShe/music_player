import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import display from '@ohos.display';
import { appStore } from '../viewmodel/AppStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
    appStore.init(this.context).catch((err: Object) => {
      hilog.error(DOMAIN, TAG, 'appStore init failed: %{public}s', JSON.stringify(err));
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
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
      this.readSafeArea(windowStage);
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
      const dark = appStore.abilityContext !== null &&
        appStore.abilityContext.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      win.setWindowLayoutFullScreen(true);
      win.setWindowBackgroundColor(dark ? '#16140F' : '#F6F3EC');
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: dark ? '#F3EFE4' : '#26221B',
        navigationBarContentColor: dark ? '#F3EFE4' : '#26221B'
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setup immersive window failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 读取系统栏/导航条避让高度（vp）存入 AppStore，供各页面统一避让 */
  private readSafeArea(windowStage: window.WindowStage): void {
    try {
      const win = windowStage.getMainWindowSync();
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const density = display.getDefaultDisplaySync().densityPixels;
      appStore.safeTopVp = sys.topRect.height / density;
      appStore.safeBottomVp = nav.bottomRect.height / density;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'read safe area failed: %{public}s', JSON.stringify(err));
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
