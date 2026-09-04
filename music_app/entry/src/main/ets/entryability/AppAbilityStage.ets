import { AbilityStage, Configuration } from '@kit.AbilityKit';
import { appStore } from '../viewmodel/AppStore';

/**
 * 应用级入口：系统配置（深浅模式、旋转/折叠展开等）变更时重应用窗口
 * 兜底色/系统栏字色，并重读避让区高度——避让值不随窗口自动刷新，
 * 过期会布局错位（UIAbility 无配置变更回调，全局配置变更只通知 AbilityStage）。
 */
export default class AppAbilityStage extends AbilityStage {
  onConfigurationUpdate(newConfig: Configuration): void {
    appStore.applyWindowChrome();
    appStore.readSafeArea();
  }
}
