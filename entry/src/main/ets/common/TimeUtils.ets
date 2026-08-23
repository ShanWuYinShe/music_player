/**
 * 毫秒时长格式化为 mm:ss
 */
export function formatTime(ms: number): string {
  if (ms <= 0 || Number.isNaN(ms)) {
    return '00:00';
  }
  const totalSeconds = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  const mm = minutes < 10 ? `0${minutes}` : `${minutes}`;
  const ss = seconds < 10 ? `0${seconds}` : `${seconds}`;
  return `${mm}:${ss}`;
}

/**
 * 毫秒总时长格式化为人类可读文案（设置页统计用）
 */
export function formatTotalDuration(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) {
    return '0 分钟';
  }
  const minutes = Math.floor(ms / 60000);
  if (minutes < 1) {
    return '不足 1 分钟';
  }
  if (minutes < 60) {
    return `${minutes} 分钟`;
  }
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (rest === 0) {
    return `${hours} 小时`;
  }
  return `${hours} 小时 ${rest} 分钟`;
}
