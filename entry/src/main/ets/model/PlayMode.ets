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
