/**
 * 歌曲数据模型（同时作为音乐库索引的持久化结构）
 */
export interface SongRecord {
  /** 唯一标识：文件名 + 大小摘要 */
  id: string;
  /** 歌名 */
  title: string;
  /** 歌手 */
  artist: string;
  /** 专辑 */
  album: string;
  /** 总时长（毫秒），未播放过时为 0，首次 prepared 后回填 */
  duration: number;
  /** 沙盒 music 目录内的文件名；在线曲目存流媒体绝对地址 */
  fileName: string;
  /** 封面缓存文件绝对路径，无封面为空字符串 */
  coverPath: string;
  /** 音频格式（大写短名，如 MP3/FLAC）；本地曲库省略（按文件名推断） */
  format?: string;
  /** 网易云付费曲目（服务端未配置登录 cookie 时仅 30~60 秒试听） */
  vip?: boolean;
}

/**
 * 判断两条歌曲记录是否同曲（用于导入去重）
 */
export function sameSong(a: SongRecord, b: SongRecord): boolean {
  return a.id === b.id;
}
