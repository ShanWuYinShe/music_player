import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SongRecord } from '../model/Song';
import { isOnlineId, onlineItemId, parseOnlineSongStore, rebuildStreamUrl, serializeOnlineSongStore } from './OnlineApi';

const TAG = 'OnlineSongStore';
const DOMAIN = 0x0003;

/** 注册表文件名（存于 filesDir） */
const STORE_FILE = 'online_songs.json';
/** 条目上限：超出按最旧注册淘汰（收藏/最近事实源本身有各自的条数上限） */
const STORE_LIMIT = 300;

/** SongRecord 深拷贝（ArkTS 禁止对象展开；coverPath 恒清空——在线歌无本地封面） */
function cloneSong(song: SongRecord, fileName: string): SongRecord {
  const record: SongRecord = {
    id: song.id,
    title: song.title,
    artist: song.artist,
    album: song.album,
    duration: song.duration,
    fileName: fileName,
    coverPath: ''
  };
  if (song.format !== undefined) {
    record.format = song.format;
  }
  if (song.vip === true) {
    record.vip = true;
  }
  return record;
}

/**
 * 在线歌曲元数据注册表：被收藏或播过的在线歌曲的 id → SongRecord 字典，
 * 持久化于 filesDir/online_songs.json。解决在线歌「播放过后重开 app 要重新
 * 加载」——收藏/最近播放只存 id，重启后靠本表还原歌名与流地址：
 * - 喜欢/最近列表补位（LibraryFilter 经 onlineSongs 参数融合展示）
 * - 播放查找兜底（PlayerController.findSong 第三级，含续播恢复）
 * 事实源仍是 UserData.favoriteIds/recentIds，本表只做元数据字典：
 * retain 清掉两头都不引用的孤儿条目。fileName 存注册时地址，换服务地址
 * 后按当前地址重拼（见 parseOnlineSongStore，服务端 id 稳定）。
 */
export class OnlineSongStore {
  private storePath: string = '';
  private baseUrl: string = '';
  /** 插入序即注册新近序：upsert 已存在先删后插（移到尾），裁剪从头删最旧 */
  private songs: Map<string, SongRecord> = new Map<string, SongRecord>();

  /** 注入目录并恢复持久化注册表（AppStore.init 在 player.init 前调用一次） */
  init(filesDir: string, baseUrl: string): void {
    this.storePath = `${filesDir}/${STORE_FILE}`;
    this.baseUrl = baseUrl;
    this.songs = new Map<string, SongRecord>();
    try {
      if (!fs.accessSync(this.storePath)) {
        return;
      }
      const restored = parseOnlineSongStore(fs.readTextSync(this.storePath), baseUrl);
      if (restored !== null) {
        for (const song of restored) {
          // 读取顺序即文件序：从头到尾注册新近度递增
          this.songs.set(song.id, song);
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'load store failed, start empty: %{public}s', JSON.stringify(err));
      this.songs = new Map<string, SongRecord>();
    }
  }

  /** 服务地址变更（设置页保存后调用）：条目流地址按新地址重拼并落盘 */
  setBaseUrl(baseUrl: string): void {
    if (baseUrl === this.baseUrl) {
      return;
    }
    this.baseUrl = baseUrl;
    for (const key of this.songs.keys()) {
      const song = this.songs.get(key);
      if (song) {
        this.songs.set(key, cloneSong(song, rebuildStreamUrl(baseUrl, onlineItemId(key))));
      }
    }
    this.persist();
  }

  /** 查询单曲元数据；返回副本（播放链路回填 duration 等不污染注册表） */
  get(id: string): SongRecord | null {
    const song = this.songs.get(id);
    return song ? cloneSong(song, song.fileName) : null;
  }

  /** 全量列表（喜欢/最近列表补位用），同样返回副本 */
  all(): SongRecord[] {
    const result: SongRecord[] = [];
    for (const song of this.songs.values()) {
      result.push(cloneSong(song, song.fileName));
    }
    return result;
  }

  /** 注册/更新一首在线歌（收藏或播放时调用）；非在线 id 忽略 */
  upsert(song: SongRecord): void {
    if (!isOnlineId(song.id) || this.storePath === '') {
      return;
    }
    this.songs.delete(song.id);
    this.songs.set(song.id, cloneSong(song, song.fileName));
    this.trimAndPersist();
  }

  /** 只保留给定 id 集合内的条目（收藏 ∪ 最近之外的条目成孤儿即删） */
  retain(ids: Set<string>): void {
    let changed = false;
    for (const key of this.songs.keys()) {
      if (!ids.has(key)) {
        this.songs.delete(key);
        changed = true;
      }
    }
    if (changed) {
      this.persist();
    }
  }

  /** 超限裁剪（从头删最旧注册）后落盘 */
  private trimAndPersist(): void {
    while (this.songs.size > STORE_LIMIT) {
      const oldest = this.songs.keys().next();
      if (oldest.done) {
        break;
      }
      this.songs.delete(oldest.value);
    }
    this.persist();
  }

  private persist(): void {
    if (this.storePath === '') {
      return;
    }
    try {
      const songs: SongRecord[] = [];
      for (const song of this.songs.values()) {
        songs.push(song);
      }
      const file = fs.openSync(this.storePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, serializeOnlineSongStore(this.baseUrl, songs));
      fs.closeSync(file);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'persist store failed: %{public}s', JSON.stringify(err));
    }
  }
}
