/**
 * 播放模式：顺序播放 / 单曲循环 / 随机播放
 */
export enum PlayMode {
  SEQUENCE = 0,
  SINGLE = 1,
  SHUFFLE = 2
}

/**
 * 循环切换到下一个播放模式
 */
export function nextPlayMode(mode: PlayMode): PlayMode {
  if (mode === PlayMode.SEQUENCE) {
    return PlayMode.SINGLE;
  }
  if (mode === PlayMode.SINGLE) {
    return PlayMode.SHUFFLE;
  }
  return PlayMode.SEQUENCE;
}

/**
 * 播放模式显示名
 */
export function playModeLabel(mode: PlayMode): string {
  if (mode === PlayMode.SINGLE) {
    return '单曲循环';
  }
  if (mode === PlayMode.SHUFFLE) {
    return '随机播放';
  }
  return '顺序播放';
}

/**
 * 「上一首只回曲首、不换轨」的判定（纯函数，可 LocalUnit 单测）。
 *
 * 播放超 RESTART_AT_HEAD_MS 时上一首回到曲首而非切上一首，但**该规则成立的
 * 前提是确有已加载的 player**：冷启动续播态（仅展示断点、player 未建）seek
 * 是空操作，此时必须退化为真正切上一首。
 *
 * previous()（执行）与 peekPrevCover()（预览）必须共用同一判据——预览若少看
 * 一个条件，就会在「实际已切歌」时给出 null，让子组件按不换轨回弹（预览骗人）。
 */
export const RESTART_AT_HEAD_MS = 5000;

export function shouldRestartAtHead(currentTimeMs: number, hasLoadedPlayer: boolean): boolean {
  return currentTimeMs > RESTART_AT_HEAD_MS && hasLoadedPlayer;
}

/**
 * 播放模式对应的系统符号名（用于 SymbolGlyph）
 */
export function playModeSymbol(mode: PlayMode): Resource {
  if (mode === PlayMode.SINGLE) {
    return $r('sys.symbol.repeat_1');
  }
  if (mode === PlayMode.SHUFFLE) {
    return $r('sys.symbol.shuffle');
  }
  return $r('sys.symbol.repeat');
}
