import { fileIo as fs } from '@kit.CoreFileKit';
import { font, UIContext } from '@kit.ArkUI';

/**
 * 水墨排印字体族：霞鹜文楷（LXGW WenKai，SIL OFL 1.1 开源可商用），
 * 经 GB2312 子集化打包 rawfile（各 3.6MB），生僻字（字集外）回退系统字体。
 * 常规字重用于正文，Medium 字重用于歌名/标题等原加粗位——文楷无 Bold，
 * 以 Medium 承担粗细层次（水墨排印讲浓淡不讲笔画粗细）。
 * 坑①：family 名必须全小写——字体引擎按小写入表（fontmgr family name:
 * wenkairegular），带大写的查询名匹配不到节点（NotifyCallbacks nodes:[]），
 * 界面静默回退黑体；
 * 坑②：$rawfile 的 Resource 形式注册在 API 24 模拟器上静默无效（调用成功
 * 但字体表无记录），须先解出到沙箱以 file:// 路径注册；
 * 坑③：全局 font.registerFont 在 UI 上下文就绪前调用会抛异常，只能放
 * 页面 aboutToAppear 之后（UIContext.getFont 版同样场景下静默无效）。
 */
export const INK_FONT_REGULAR: string = 'wenkairegular';
export const INK_FONT_MEDIUM: string = 'wenkaimedium';

/** rawfile 内的字体文件（familyName, 文件名）对 */
const INK_FONTS: string[][] = [
  [INK_FONT_REGULAR, 'WenKai-Regular.ttf'],
  [INK_FONT_MEDIUM, 'WenKai-Medium.ttf']
];

let inkFontsRegistered = false;

/** 注册文楷字体：在根页面 Index.aboutToAppear 调用（UI 上下文就绪后）；
 * 字体解出到沙箱 filesDir 落盘复用，重复调用以标志位防重入 */
export function ensureInkFonts(ui: UIContext): void {
  if (inkFontsRegistered) {
    return;
  }
  inkFontsRegistered = true;
  try {
    const ctx = ui.getHostContext();
    if (ctx === undefined) {
      throw new Error('host context undefined');
    }
    const fontDir = `${ctx.filesDir}/ink_fonts`;
    if (!fs.accessSync(fontDir)) {
      fs.mkdirSync(fontDir, true);
    }
    for (let i = 0; i < INK_FONTS.length; i++) {
      const family = INK_FONTS[i][0];
      const asset = INK_FONTS[i][1];
      const target = `${fontDir}/${asset}`;
      if (!fs.accessSync(target)) {
        const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync(`fonts/${asset}`);
        const file = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
        } finally {
          fs.closeSync(file);
        }
      }
      font.registerFont({ familyName: family, familySrc: `file://${target}` });
    }
  } catch (err) {
    inkFontsRegistered = false;
    console.error(`register ink fonts failed: ${err instanceof Error ? err.message : JSON.stringify(err)}`);
  }
}
