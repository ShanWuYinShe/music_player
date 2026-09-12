import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import formInfo from '@ohos.app.form.formInfo';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { readFormState, addFormId, removeFormId } from '../common/FormStateFile';

const TAG = 'MusicFormAbility';
const DOMAIN = 0x0002;

interface CardData {
  title: string;
  artist: string;
  cover: string;
  playing: boolean;
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

  onUpdateForm(formId: string): void {
    formProvider.updateForm(formId, formBindingData.createFormBindingData(this.buildCardData()))
      .catch((err: Object) => {
        hilog.warn(DOMAIN, TAG, 'updateForm failed: %{public}s', JSON.stringify(err));
      });
  }

  private buildCardData(): CardData {
    const state = readFormState(this.context.filesDir);
    if (state === null || state.title === '') {
      return { title: '', artist: '', cover: '', playing: false };
    }
    return {
      title: state.title,
      artist: state.artist,
      cover: state.coverPath,
      playing: state.playing
    };
  }
}
