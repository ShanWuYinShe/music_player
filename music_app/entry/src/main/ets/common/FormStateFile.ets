import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'FormStateFile';
const DOMAIN = 0x0002;

/**
 * 桌面卡片共享的播放状态快照。主进程写、FormExtensionAbility 读：
 * 两个进程不共享内存，应用沙箱内 filesDir 下的 JSON 文件是唯一交接点。
 */
export interface FormPlaybackState {
  /** 曲名，空串=无曲目（卡片显示占位态） */
  title: string;
  artist: string;
  /** 封面文件路径，空串=无封面 */
  coverPath: string;
  playing: boolean;
}

export function formStatePath(filesDir: string): string {
  return `${filesDir}/form_state.json`;
}

/** 写入状态快照（整文件覆盖）；失败仅记日志，绝不影响播放 */
export function writeFormState(filesDir: string, state: FormPlaybackState): void {
  try {
    const file = fs.openSync(formStatePath(filesDir),
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, JSON.stringify(state));
    fs.closeSync(file);
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'write form state failed: %{public}s', JSON.stringify(err));
  }
}

/** 读取状态快照；文件不存在或损坏返回 null（卡片自行回退占位态） */
export function readFormState(filesDir: string): FormPlaybackState | null {
  try {
    const raw = fs.readTextSync(formStatePath(filesDir));
    const parsed = JSON.parse(raw) as FormPlaybackState;
    if (typeof parsed.title !== 'string' || typeof parsed.playing !== 'boolean') {
      return null;
    }
    return parsed;
  } catch (err) {
    return null;
  }
}

/**
 * 已添加卡片的 formId 列表（form_ids.json）：系统不给第三方查询本应用
 * 卡片实例的 formId，只能在 FormAbility.onAddForm 时从 want 记录、
 * onRemoveForm 时移除，与状态快照一样以文件在进程间共享。
 */
export function readFormIds(filesDir: string): string[] {
  try {
    const raw = fs.readTextSync(`${filesDir}/form_ids.json`);
    const parsed = JSON.parse(raw) as string[];
    return Array.isArray(parsed) ? parsed : [];
  } catch (err) {
    return [];
  }
}

export function writeFormIds(filesDir: string, ids: string[]): void {
  try {
    const file = fs.openSync(`${filesDir}/form_ids.json`,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, JSON.stringify(ids));
    fs.closeSync(file);
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'write form ids failed: %{public}s', JSON.stringify(err));
  }
}

/** 登记一个新卡片实例（去重） */
export function addFormId(filesDir: string, formId: string): void {
  const ids = readFormIds(filesDir);
  if (ids.indexOf(formId) < 0) {
    ids.push(formId);
    writeFormIds(filesDir, ids);
  }
}

/** 移除已删除的卡片实例 */
export function removeFormId(filesDir: string, formId: string): void {
  const ids = readFormIds(filesDir);
  const next = ids.filter((id) => id !== formId);
  if (next.length !== ids.length) {
    writeFormIds(filesDir, next);
  }
}
