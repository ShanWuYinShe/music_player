import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'FormStateFile';
const DOMAIN = 0x0002;

/**
 * 卡片控制指令的公共事件名：卡片按钮（message 型）→ FormAbility 发布 →
 * 主进程 AppStore 订阅执行播放控制（FormExtension 进程与主进程不共享
 * 内存，公共事件是跨进程转发指令的通道）。
 */
export const APP_BUNDLE_NAME = 'com.lsyb.musicplayer';
export const CARD_ACTION_EVENT = 'com.lsyb.musicplayer.card_action';

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
  /** 播放进度（ms 与 0..1 比例）：2x4 卡片进度条；无曲目时为 0 */
  positionMs: number;
  durationMs: number;
  progress: number;
  /** 锚点时刻（墙钟 ms）：positionMs 的采样时刻。卡片据此本地外推
   * 走秒（playing 时显示位置 = positionMs + now - anchorAt），主进程
   * 因此无需周期推送——与锁屏 AVSession 的外推模型同构 */
  anchorAt: number;
}

/** 状态快照落盘路径（主进程写 / FormExtension 进程读的进程间交接文件） */
function formStatePath(filesDir: string): string {
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

/**
 * 卡片 LocalStorage 绑定载荷：键与卡片页 @LocalStorageProp 一一对应。
 * 快照字段 coverPath 须映射为卡片键 cover——主进程直接推原始快照时
 * 卡片收不到 cover，封面会停留在加卡时刻的曲目（已踩坑）。
 */
export interface CardBindingPayload {
  title: string;
  artist: string;
  cover: string;
  playing: boolean;
  positionMs: number;
  durationMs: number;
  progress: number;
  anchorAt: number;
}

/** 快照 → 卡片绑定载荷（FormAbility 冷启动读文件与主进程推送共用同一形状） */
export function toCardPayload(state: FormPlaybackState): CardBindingPayload {
  return {
    title: state.title,
    artist: state.artist,
    cover: state.coverPath,
    playing: state.playing,
    positionMs: state.positionMs,
    durationMs: state.durationMs,
    progress: state.progress,
    anchorAt: state.anchorAt
  };
}

/** 无曲目占位快照（卡片冷启动且尚无状态文件时用） */
export function emptyFormState(): FormPlaybackState {
  return { title: '', artist: '', coverPath: '', playing: false, positionMs: 0, durationMs: 0, progress: 0, anchorAt: 0 };
}

/** 读取状态快照；文件不存在或损坏返回 null（卡片自行回退占位态） */
export function readFormState(filesDir: string): FormPlaybackState | null {
  try {
    const raw = fs.readTextSync(formStatePath(filesDir));
    const parsed = JSON.parse(raw) as FormPlaybackState;
    if (typeof parsed.title !== 'string' || typeof parsed.playing !== 'boolean') {
      return null;
    }
    // 逐字段归一化：旧版本快照可能缺进度字段，不能把 undefined 透传给卡片
    return {
      title: parsed.title,
      artist: typeof parsed.artist === 'string' ? parsed.artist : '',
      coverPath: typeof parsed.coverPath === 'string' ? parsed.coverPath : '',
      playing: parsed.playing,
      positionMs: typeof parsed.positionMs === 'number' ? parsed.positionMs : 0,
      durationMs: typeof parsed.durationMs === 'number' ? parsed.durationMs : 0,
      progress: typeof parsed.progress === 'number' ? parsed.progress : 0,
      anchorAt: typeof parsed.anchorAt === 'number' ? parsed.anchorAt : 0
    };
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
