import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import formInfo from '@ohos.app.form.formInfo';
import { Want } from '@kit.AbilityKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { readFormState, addFormId, removeFormId, APP_BUNDLE_NAME, CARD_ACTION_EVENT, toCardPayload, emptyFormState, CardBindingPayload } from '../common/FormStateFile';

const TAG = 'MusicFormAbility';
const DOMAIN = 0x0002;

/** postCardAction message 事件的 payload 形态（params 序列化为 JSON 串） */
interface CardActionMessage {
  method?: string;
  params?: CardActionParams;
}

interface CardActionParams {
  method?: string;
}

/**
 * 桌面服务卡片后台：只在卡片添加/定时刷新时被系统拉起，读落盘的播放
 * 状态快照（FormStateFile，主进程在切歌/启停时写入并主动推送）渲染。
 * 本进程无法访问主进程的 PlayerController 内存状态。
 */
export default class MusicFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    // 登记卡片实例 id：主进程推送刷新的依据（系统不提供第三方查询本应用
    // 卡片实例的接口，只能在这里从 want 记录、onRemoveForm 移除）
    const params = want.parameters;
    const formId = params ? params[formInfo.FormParam.IDENTITY_KEY] : undefined;
    if (typeof formId === 'string') {
      addFormId(this.context.filesDir, formId);
    }
    hilog.info(DOMAIN, TAG, 'onAddForm');
    return formBindingData.createFormBindingData(this.buildCardData());
  }

  onRemoveForm(formId: string): void {
    removeFormId(this.context.filesDir, formId);
  }

  /**
   * 卡片控制按钮（message 型）：解析指令并以公共事件转发给主进程执行
   * （FormExtension 进程无法访问主进程播放器；本进程也没有拉起 UIAbility
   * 的能力——主进程被杀时本次点击静默无效，点卡片空白进应用即恢复）。
   */
  onFormEvent(formId: string, message: string): void {
    let method = '';
    try {
      const parsed = JSON.parse(message) as CardActionMessage;
      method = parsed.method ?? parsed.params?.method ?? '';
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'card message parse failed: %{public}s', message);
    }
    if (method !== 'toggle' && method !== 'next' && method !== 'previous') {
      return;
    }
    commonEventManager.publish(CARD_ACTION_EVENT, {
      bundleName: APP_BUNDLE_NAME,
      data: method
    }, (err) => {
      if (err) {
        hilog.warn(DOMAIN, TAG, 'publish card action failed: %{public}s', JSON.stringify(err));
      } else {
        hilog.info(DOMAIN, TAG, 'card action published: %{public}s', method);
      }
    });
  }

  onUpdateForm(formId: string): void {
    formProvider.updateForm(formId, formBindingData.createFormBindingData(this.buildCardData()))
      .catch((err: Object) => {
        hilog.warn(DOMAIN, TAG, 'updateForm failed: %{public}s', JSON.stringify(err));
      });
  }

  private buildCardData(): CardBindingPayload {
    const state = readFormState(this.context.filesDir);
    return toCardPayload(state !== null ? state : emptyFormState());
  }
}
