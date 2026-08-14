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
