/** 文本显示辅助 */

/** 歌名首字占位：按 code point 取首字（emoji 等增补平面字符不会被劈成
 * 乱码）；空串返回空。占位块统一走它，不要自己 substring(0, 1) */
export function firstGlyph(text: string): string {
  if (text === '') {
    return '';
  }
  const code = text.codePointAt(0);
  return code === undefined ? '' : String.fromCodePoint(code);
}
