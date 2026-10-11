/**
 * 曲库文件名元数据解析（纯函数，零 @ohos 依赖，LocalUnit 可直接单测）。
 *
 * 约定（AGENTS.md 与 skill `music-server-library` 的服务端口径同源）：
 *   - 「歌手 - 歌名.ext」按第一个「 - 」分割；
 *   - 兼容可选批量命名序号前缀（「demoXX_」等，与 rawfile 演示曲目一致）；
 *   - 无分隔符时整体作歌名，歌手填「本地音乐」。
 *
 * 从 MusicLibrary.fillFromFileName 抽出：该约定是曲库元数据的唯一来源
 * （无 ID3 标签时的兜底），此前是 private 方法且零测试覆盖，改解析逻辑
 * 时无从验证是否破坏存量命名。
 */

/** 无「歌手 - 歌名」分隔符时的歌手兜底值 */
export const LOCAL_ARTIST_FALLBACK = '本地音乐';

/** 文件名解析结果 */
export interface FileNameMeta {
  artist: string;
  title: string;
}

/**
 * 从文件名解析歌手与歌名。
 * ① 去扩展名（无点或点在首位则不去）；
 * ② 剥离「字母(可选)+数字(必含)+ _ 或 - 」形式的序号前缀；
 * ③ 按第一个「 - 」分割；无分隔符则整体作歌名。
 */
export function parseFileNameMeta(fileName: string): FileNameMeta {
  let name = fileName;
  const dot = name.lastIndexOf('.');
  if (dot > 0) {
    name = name.substring(0, dot);
  }
  const demoPrefix = /^demo\d+_/.exec(name);
  if (demoPrefix) {
    name = name.substring(demoPrefix[0].length);
  }
  const sep = name.indexOf(' - ');
  if (sep > 0) {
    return { artist: name.substring(0, sep).trim(), title: name.substring(sep + 3).trim() };
  }
  return { artist: LOCAL_ARTIST_FALLBACK, title: name.trim() };
}
