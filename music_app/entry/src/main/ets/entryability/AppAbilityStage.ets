import { AbilityStage, Configuration } from '@kit.AbilityKit';
import { appStore } from '../viewmodel/AppStore';

/**
 * 应用级入口：系统配置（深浅模式）变更时重应用窗口兜底色与系统栏字色，
 * 使硬编码的 window chrome 跟随当前模式（UIAbility 无配置变更回调，
 * 全局配置变更只通知 AbilityStage）。
 */
export default class AppAbilityStage extends AbilityStage {
  onConfigurationUpdate(newConfig: Configuration): void {
    appStore.applyWindowChrome();
  }
}
