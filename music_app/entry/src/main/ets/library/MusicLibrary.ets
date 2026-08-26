import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { SongRecord } from '../model/Song';
import { parseId3Async } from './Id3Parser';

const TAG = 'MusicLibrary';
const DOMAIN = 0x0001;
const LIBRARY_FILE = 'library.json';
const SUPPORTED_EXTS = ['mp3', 'wav', 'flac', 'm4a', 'aac', 'ogg'];
/** 高频持久化变更的合并窗口（毫秒）：窗口内多次变更只落盘一次 */
const SAVE_DEBOUNCE_MS = 500;
const utf8Decoder = util.TextDecoder.create('utf-8');

/**
 * 本地音乐库：管理沙盒内音乐文件与索引持久化。
 * 文件来源两类：AudioViewPicker 选中的媒体库 URI（复制入沙盒）、rawfile 内置演示曲目。
 */
export class MusicLibrary {
  private context: common.Context | null = null;
  private songs: SongRecord[] = [];
  /** 防抖落盘定时器 id（-1 无待写任务） */
  private saveTimerId: number = -1;

  /** 注入应用上下文并加载持久化索引 */
  init(context: common.Context): void {
    this.context = context;
    this.ensureDir(this.musicDir());
    this.ensureDir(this.coverDir());
    this.load();
  }

  getAllSongs(): SongRecord[] {
    return this.songs;
  }

  getSongById(id: string): SongRecord | null {
    for (const song of this.songs) {
      if (song.id === id) {
        return song;
      }
    }
    return null;
  }

  /** 歌曲文件绝对路径 */
  songPath(song: SongRecord): string {
    return `${this.musicDir()}/${song.fileName}`;
  }

  /**
   * 从系统媒体库 URI 导入（AudioViewPicker 授权后的 file://media/... 链接）
   * @returns 实际新增数量
   */
  async importFromUris(uris: string[]): Promise<number> {
    let added = 0;
    for (const uri of uris) {
      try {
        const record = await this.importUri(uri);
        if (record) {
          this.songs.push(record);
          added++;
        }
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'import uri failed: %{public}s', JSON.stringify(err));
      }
    }
    if (added > 0) {
      this.save();
    }
    return added;
  }

  /**
   * 从 rawfile 载入演示曲目（文件名约定 demoXX_歌手 - 歌名.ext）
   * @returns 实际新增数量
   */
  async importDemoTracks(): Promise<number> {
    if (!this.context) {
      return 0;
    }
    const demos: string[] = [
      'demo01_湖畔晚风 - 雨后琶音.wav',
      'demo02_远山晨雾 - 晨光旋律.wav',
      'demo03_拾光者 - 温柔节拍.wav'
    ];
    let added = 0;
    for (const demoName of demos) {
      try {
        const target = `${this.musicDir()}/${demoName}`;
        if (fs.accessSync(target)) {
          continue;
        }
        const content: Uint8Array = await this.context.resourceManager.getRawFileContent(demoName);
        this.writeBytes(target, content);
        const record = await this.makeRecord(target, demoName);
        if (this.songs.some((item) => item.id === record.id)) {
          continue; // 双击等并发触发的兜底：已有同名记录不入索引
        }
        this.songs.push(record);
        added++;
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'import demo failed: %{public}s', JSON.stringify(err));
      }
    }
    if (added > 0) {
      this.save();
    }
    return added;
  }

  /** 从音乐库移除歌曲（同时删除沙盒文件与封面缓存） */
  removeSong(id: string): void {
    const song = this.getSongById(id);
    if (!song) {
      return;
    }
    const path = this.songPath(song);
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
      if (song.coverPath && fs.accessSync(song.coverPath)) {
        fs.unlinkSync(song.coverPath);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'remove files failed: %{public}s', JSON.stringify(err));
    }
    this.songs = this.songs.filter((item) => item.id !== id);
    this.save();
  }

  /**
   * 清空曲库：删除沙盒内全部音乐文件与封面缓存并重置索引。
   * 调用方需先停止播放（当前 fd 指向待删文件）。
   */
  clearAll(): void {
    this.removeDirContents(this.musicDir());
    this.removeDirContents(this.coverDir());
    this.songs = [];
    this.save();
  }

  /** 曲库总时长（毫秒），未播放过的曲目按 0 计 */
  totalDurationMs(): number {
    let total = 0;
    for (const song of this.songs) {
      if (song.duration > 0) {
        total += song.duration;
      }
    }
    return total;
  }

  /** 删除目录内全部文件（保留目录本身） */
  private removeDirContents(dir: string): void {
    try {
      if (!fs.accessSync(dir)) {
        return;
      }
      const names = fs.listFileSync(dir);
      for (const name of names) {
        try {
          fs.unlinkSync(`${dir}/${name}`);
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'unlink %{public}s failed: %{public}s', name, JSON.stringify(err));
        }
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'clear dir failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 首次播放获得时长后回填；高频变更走防抖合并落盘 */
  updateDuration(id: string, duration: number): void {
    const song = this.getSongById(id);
    if (song && song.duration !== duration) {
      song.duration = duration;
      this.scheduleSave();
    }
  }

  /** 高频变更的合并持久化：窗口内多次变更只全量写盘一次 */
  private scheduleSave(): void {
    if (this.saveTimerId >= 0) {
      clearTimeout(this.saveTimerId);
    }
    this.saveTimerId = setTimeout(() => {
      this.saveTimerId = -1;
      this.save();
    }, SAVE_DEBOUNCE_MS);
  }

  private async importUri(uri: string): Promise<SongRecord | null> {
    const displayName = decodeURIComponent(uri.substring(uri.lastIndexOf('/') + 1));
    const dot = displayName.lastIndexOf('.');
    const ext = dot >= 0 ? displayName.substring(dot + 1).toLowerCase() : '';
    const safeExt = SUPPORTED_EXTS.includes(ext) ? ext : 'mp3';
    const normalized = this.normalizedFileName(displayName, safeExt);
    // 拷贝前按「规范化文件名_大小」查重：直接重复导入同一 URI 时 uniqueName
    // 会因同名冲突改出新文件名（id 随之不同），仅靠拷贝后比对 id 永远不命中。
    let size = 0;
    try {
      size = fs.statSync(uri).size;
    } catch (err) {
      // 个别源 URI 不支持 stat：退回拷贝后判定
    }
    if (size > 0 && this.songs.some((item) => item.id === `${normalized}_${size}`)) {
      return null;
    }
    // 保留原文件名便于用户识别；同名不同内容靠 id（名称+大小）去重
    const target = `${this.musicDir()}/${this.uniqueName(normalized)}`;
    await fs.copyFile(uri, target);
    const record = await this.makeRecord(target);
    if (this.songs.some((item) => item.id === record.id)) {
      fs.unlinkSync(target); // stat 失败漏判的重复导入，丢弃新拷贝
      return null;
    }
    return record;
  }

  /** 规范化显示名为沙盒文件名基础形态（去非法字符，确保带扩展名） */
  private normalizedFileName(displayName: string, ext: string): string {
    let base = displayName.replace(/[\/\\:*?"<>|]/g, '_');
    if (!base.includes('.')) {
      base = `${base}.${ext}`;
    }
    return base;
  }

  /** 在规范化文件名基础上生成沙盒内不冲突的文件名 */
  private uniqueName(base: string): string {
    let candidate = base;
    let counter = 1;
    while (fs.accessSync(`${this.musicDir()}/${candidate}`)) {
      const dotIdx = base.lastIndexOf('.');
      candidate = `${base.substring(0, dotIdx)}_${counter}${base.substring(dotIdx)}`;
      counter++;
    }
    return candidate;
  }

  /** 由沙盒文件生成歌曲记录：mp3 走 ID3（taskpool 子线程解析），其余按文件名解析「歌手 - 歌名」 */
  private async makeRecord(path: string, rawFileName?: string): Promise<SongRecord> {
    const fileName = path.substring(path.lastIndexOf('/') + 1);
    const size = fs.statSync(path).size;
    const record: SongRecord = {
      id: `${fileName}_${size}`,
      title: '',
      artist: '',
      album: '',
      duration: 0,
      fileName: fileName,
      coverPath: ''
    };
    if (fileName.toLowerCase().endsWith('.mp3')) {
      const tag = await parseId3Async(path);
      record.title = tag.title;
      record.artist = tag.artist;
      record.album = tag.album;
      if (tag.coverData && tag.coverData.length > 0 && this.context) {
        record.coverPath = this.saveCover(record.id, tag.coverData);
      }
    }
    if (!record.title) {
      this.fillFromFileName(record, rawFileName ?? fileName);
    }
    return record;
  }

  /** 文件名解析：优先「歌手 - 歌名」，否则整名做歌名 */
  private fillFromFileName(record: SongRecord, fileName: string): void {
    let name = fileName;
    const dot = name.lastIndexOf('.');
    if (dot > 0) {
      name = name.substring(0, dot);
    }
    // 去掉演示曲目前缀 demoXX_
    const demoPrefix = /^demo\d+_/.exec(name);
    if (demoPrefix) {
      name = name.substring(demoPrefix[0].length);
    }
    const sep = name.indexOf(' - ');
    if (sep > 0) {
      record.artist = name.substring(0, sep).trim();
      record.title = name.substring(sep + 3).trim();
    } else {
      record.title = name.trim();
      record.artist = '本地音乐';
    }
  }

  private saveCover(id: string, data: Uint8Array): string {
    const path = `${this.coverDir()}/${id}.jpg`;
    this.writeBytes(path, data);
    return path;
  }

  /** 将字节数组写入文件（writeSync 仅接受 ArrayBuffer） */
  private writeBytes(path: string, data: Uint8Array): void {
    const buffer = new ArrayBuffer(data.byteLength);
    new Uint8Array(buffer).set(data);
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    fs.writeSync(file.fd, buffer);
    fs.closeSync(file);
  }

  private save(): void {
    if (!this.context) {
      return;
    }
    try {
      const file = fs.openSync(this.libraryPath(), fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(this.songs));
      fs.closeSync(file);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'save library failed: %{public}s', JSON.stringify(err));
    }
  }

  private load(): void {
    try {
      if (!fs.accessSync(this.libraryPath())) {
        return;
      }
      const file = fs.openSync(this.libraryPath(), fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(this.libraryPath());
      const buffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      fs.closeSync(file);
      const text = utf8Decoder.decodeWithStream(new Uint8Array(buffer));
      const parsed: SongRecord[] = JSON.parse(text) as SongRecord[];
      // 过滤已丢失文件的记录
      this.songs = parsed.filter((song) => fs.accessSync(`${this.musicDir()}/${song.fileName}`));
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'load library failed: %{public}s', JSON.stringify(err));
      this.songs = [];
    }
  }

  private musicDir(): string {
    return `${this.context?.filesDir}/music`;
  }

  private coverDir(): string {
    return `${this.context?.filesDir}/covers`;
  }

  private libraryPath(): string {
    return `${this.context?.filesDir}/${LIBRARY_FILE}`;
  }

  private ensureDir(path: string): void {
    if (!fs.accessSync(path)) {
      fs.mkdirSync(path);
    }
  }
}
