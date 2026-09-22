import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { evictOrder } from '../source/OnlineApi';

const TAG = 'OnlineCache';
const DOMAIN = 0x0003;

/** 在线音频整曲缓存上限（字节）：约容纳上百首常听曲目，超限按末次访问淘汰 */
const MAX_CACHE_BYTES = 500 * 1024 * 1024;
/** 下载连接/读取超时（毫秒）：整曲下载给足读取宽限 */
const CONNECT_TIMEOUT_MS = 8000;
const READ_TIMEOUT_MS = 60000;
/** 索引落盘节流：命中攒够该次数才落盘（高频切歌不写文件） */
const PERSIST_DIRTY_LIMIT = 20;
/** 索引落盘节流：距上次落盘超该时长（毫秒）也落盘（低频命中不丢 lastAccess） */
const PERSIST_INTERVAL_MS = 30000;
/** 索引文件名（存于缓存目录内） */
const INDEX_FILE = 'index.json';
/** 同时进行的整曲下载上限：播放伴随下载 + 收藏批量补下载共用此队列 */
const MAX_ACTIVE_DOWNLOADS = 2;

/** 待下载任务（prefetch 入队；shouldContinue 在出队与每个分片时复核） */
interface PendingDownload {
  songId: string;
  url: string;
  shouldContinue: () => boolean;
}

/** 缓存索引条目 */
class CacheEntry {
  size: number = 0;
  lastAccess: number = 0;
}

/**
 * 在线音频整曲缓存：
 * 播放在线曲目时 AVPlayer 直接播 http 流，同时后台整曲下载落盘；
 * 复播命中即走本地 fd（秒开、可离线、不重复耗流量）。
 * key 为 SongRecord.id（online: 前缀已隔离本地 id，服务端 id 稳定）；
 * VIP 未登录试听片段由调用方判定不可缓存（key 不区分试听/完整，避免
 * 登录后试听字节污染完整音频），本类只管存取与淘汰。
 * 下载经排队限并发（MAX_ACTIVE_DOWNLOADS）；收藏曲目由外部同步进
 * pinned 集合——淘汰时垫后，仅当非钉住总量自身超限才会轮到它们。
 */
export class OnlineCache {
  private dir: string = '';
  private index: Map<string, CacheEntry> = new Map<string, CacheEntry>();
  /** 已入队或正在下载的 key（防重复下载；切歌取消后移出） */
  private inflight: Set<string> = new Set<string>();
  /** 收藏钉住集合（事实源为收藏∩注册表，启动/收藏变更时外部整体替换） */
  private pinned: Set<string> = new Set<string>();
  /** 待下载队列与在途下载数（限并发，收藏批量补下载不爆发） */
  private queue: PendingDownload[] = [];
  private activeCount: number = 0;
  /** 落盘节流态：攒够次数或超间隔才写文件（高频切歌不碰磁盘） */
  private dirtyCount: number = 0;
  private lastPersistMs: number = 0;

  init(context: common.UIAbilityContext): void {
    this.dir = `${context.filesDir}/online_cache`;
    try {
      if (!fs.accessSync(this.dir)) {
        fs.mkdirSync(this.dir);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'ensure cache dir failed: %{public}s', JSON.stringify(err));
      return;
    }
    this.loadIndex();
    this.reconcile();
  }

  /** 命中返回本地绝对路径（调用方 openSync 走 fd 播放），未命中返回空串 */
  lookup(songId: string): string {
    if (this.dir === '') {
      return '';
    }
    const entry = this.index.get(songId);
    if (!entry) {
      return '';
    }
    const path = this.filePath(songId);
    try {
      if (!fs.accessSync(path)) {
        this.index.delete(songId);
        this.markDirty(true); // 条目删除须落盘（低频，立即写）
        return '';
      }
    } catch (err) {
      return '';
    }
    entry.lastAccess = Date.now();
    this.markDirty(false); // 高频命中只记内存，攒够再落盘
    hilog.info(DOMAIN, TAG, 'cache hit: %{public}s', songId);
    return path;
  }

  /** 索引变脏：攒够次数或超间隔才落盘；force 立即落盘（删除/淘汰/退出） */
  private markDirty(force: boolean): void {
    if (force) {
      this.flush();
      return;
    }
    this.dirtyCount += 1;
    if (this.dirtyCount >= PERSIST_DIRTY_LIMIT || Date.now() - this.lastPersistMs >= PERSIST_INTERVAL_MS) {
      this.flush();
    }
  }

  /** 立即落盘（退出/后台钩子与强制点调用，顺手清零节流计数） */
  flush(): void {
    this.dirtyCount = 0;
    this.lastPersistMs = Date.now();
    this.persistIndex();
  }

  /** 是否已有该曲完整缓存（收藏同步时判定是否需要主动补下载） */
  has(songId: string): boolean {
    return this.index.has(songId);
  }

  /** 收藏钉住集合整体替换（外部事实源推导后同步；不持久化，重启重建） */
  setPinned(ids: Set<string>): void {
    this.pinned = ids;
  }

  /**
   * 后台整曲下载：播放同时存盘，下次复播命中。
   * 任务入队限并发（收藏批量补下载时不爆发）；shouldContinue 在出队与
   * 每个分片回调复核——切歌后旧下载中止并删除半成品，不浪费流量；
   * 下载失败静默（仅打日志），不影响当前播放。
   */
  prefetch(songId: string, url: string, shouldContinue: () => boolean): void {
    if (this.dir === '' || this.index.has(songId) || this.inflight.has(songId)) {
      return;
    }
    this.inflight.add(songId);
    this.queue.push({ songId: songId, url: url, shouldContinue: shouldContinue });
    this.pump();
  }

  /** 调度：空闲额度内出队启动；出队时已失效（切歌取消等）的任务直接丢弃 */
  private pump(): void {
    while (this.activeCount < MAX_ACTIVE_DOWNLOADS && this.queue.length > 0) {
      const task = this.queue.shift() as PendingDownload;
      if (!task.shouldContinue()) {
        this.inflight.delete(task.songId);
        continue;
      }
      this.activeCount += 1;
      this.startDownload(task);
    }
  }

  /** 单个下载任务执行体（原 prefetch 主体） */
  private startDownload(task: PendingDownload): void {
    const songId = task.songId;
    const path = this.filePath(songId);
    let fd = -1;
    let done = false;
    const request = http.createHttp();
    const finish = (success: boolean): void => {
      if (done) {
        return;
      }
      done = true;
      this.activeCount -= 1;
      this.inflight.delete(songId);
      try {
        request.destroy();
      } catch (err) {
      }
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (err) {
        }
        fd = -1;
      }
      if (!success) {
        try {
          if (fs.accessSync(path)) {
            fs.unlinkSync(path);
          }
        } catch (err) {
        }
        this.pump();
        return;
      }
      try {
        const size = fs.statSync(path).size;
        if (size <= 0) {
          fs.unlinkSync(path);
          this.pump();
          return;
        }
        const entry = new CacheEntry();
        entry.size = size;
        entry.lastAccess = Date.now();
        this.index.set(songId, entry);
        this.persistIndex();
        this.evictIfNeeded();
        hilog.info(DOMAIN, TAG, 'cached: %{public}s %{public}d bytes', songId, size);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'commit cache failed: %{public}s', JSON.stringify(err));
      }
      this.pump();
    };
    try {
      fd = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC).fd;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'open cache file failed: %{public}s', JSON.stringify(err));
      finish(false);
      return;
    }
    request.on('dataReceive', (buf: ArrayBuffer) => {
      if (!task.shouldContinue()) {
        finish(false);
        return;
      }
      try {
        fs.writeSync(fd, buf);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'write cache failed: %{public}s', JSON.stringify(err));
        finish(false);
      }
    });
    request.on('dataEnd', () => {
      finish(task.shouldContinue());
    });
    try {
      request.requestInStream(task.url, {
        method: http.RequestMethod.GET,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS
      }, (err, code) => {
        if (code !== 200) {
          hilog.warn(DOMAIN, TAG, 'prefetch http %{public}d: %{public}s', code, songId);
          finish(false);
        }
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'prefetch start failed: %{public}s', JSON.stringify(err));
      finish(false);
    }
  }

  /** 缓存文件名：id 含 online:/斜杠等非法字符时转义——折叠有理论碰撞
   *（不同 id 折出同名），转义过的名字追加短 hash 兜底；干净 id 名字不变，
   * 已缓存文件零迁移 */
  private filePath(songId: string): string {
    const safe = songId.replace(/[^a-zA-Z0-9_-]/g, '_');
    if (safe === songId) {
      return `${this.dir}/${safe}.audio`;
    }
    let hash = 5381;
    for (let i = 0; i < songId.length; i++) {
      hash = ((hash * 33) ^ songId.charCodeAt(i)) & 0x7fffffff;
    }
    return `${this.dir}/${safe}.${hash.toString(36)}.audio`;
  }

  private indexPath(): string {
    return `${this.dir}/${INDEX_FILE}`;
  }

  private loadIndex(): void {
    try {
      if (!fs.accessSync(this.indexPath())) {
        return;
      }
      const file = fs.openSync(this.indexPath(), fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(this.indexPath());
      const buf = new ArrayBuffer(stat.size);
      const read = fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const text = String.fromCharCode(...new Uint8Array(buf.slice(0, read)));
      const parsed = JSON.parse(text) as Record<string, CacheEntry>;
      if (parsed && typeof parsed === 'object') {
        const restored = new Map<string, CacheEntry>();
        for (const key of Object.keys(parsed)) {
          const item = parsed[key];
          if (item && typeof item.size === 'number' && typeof item.lastAccess === 'number') {
            const entry = new CacheEntry();
            entry.size = item.size;
            entry.lastAccess = item.lastAccess;
            restored.set(key, entry);
          }
        }
        this.index = restored;
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'load index failed, start empty: %{public}s', JSON.stringify(err));
      this.index = new Map<string, CacheEntry>();
    }
  }

  private persistIndex(): void {
    if (this.dir === '') {
      return;
    }
    try {
      const obj: Record<string, CacheEntry> = {};
      for (const key of this.index.keys()) {
        const entry = this.index.get(key);
        if (entry) {
          obj[key] = entry;
        }
      }
      const text = JSON.stringify(obj);
      const file = fs.openSync(this.indexPath(), fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
      fs.closeSync(file);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'persist index failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 旧命名迁移：短 hash 引入前的缓存名是 `${safe}.audio`（无 hash 后缀），
   * 逐个改名到当前命名——否则升级后旧缓存全部对不上索引、被当孤儿清空 */
  private migrateLegacyNames(names: Set<string>): void {
    for (const key of this.index.keys()) {
      const safe = key.replace(/[^a-zA-Z0-9_-]/g, '_');
      if (safe === key) {
        continue;
      }
      const legacy = `${safe}.audio`;
      if (!names.has(legacy)) {
        continue;
      }
      const current = this.filePath(key).split('/').pop() ?? '';
      try {
        if (names.has(current)) {
          fs.unlinkSync(`${this.dir}/${legacy}`); // 新名已在（重下过），旧名作废
        } else {
          fs.renameSync(`${this.dir}/${legacy}`, `${this.dir}/${current}`);
          names.add(current);
        }
        names.delete(legacy);
      } catch (err) {
        // 迁移失败不影响功能：该文件会被当孤儿清掉，缓存 miss 重下
      }
    }
  }

  /** 对账：删孤儿文件（在盘不在索引）、丢过期索引（在索引不在盘）、超限淘汰 */
  private reconcile(): void {
    try {
      const names = new Set<string>(fs.listFileSync(this.dir));
      this.migrateLegacyNames(names);
      for (const key of this.index.keys()) {
        const segs = this.filePath(key).split('/');
        names.delete(segs[segs.length - 1]);
        if (!fs.accessSync(this.filePath(key))) {
          this.index.delete(key);
        }
      }
      names.delete(INDEX_FILE);
      for (const orphan of names) {
        try {
          fs.unlinkSync(`${this.dir}/${orphan}`);
        } catch (err) {
        }
      }
      this.persistIndex();
      this.evictIfNeeded();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'reconcile failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 超限淘汰：按 evictOrder 序删除（非钉住最旧在前、钉住垫后；在途不参与） */
  private evictIfNeeded(): void {
    let total = 0;
    for (const entry of this.index.values()) {
      total += entry.size;
    }
    if (total <= MAX_CACHE_BYTES) {
      return;
    }
    for (const key of evictOrder(this.index, this.pinned, this.inflight)) {
      if (total <= MAX_CACHE_BYTES) {
        break;
      }
      const entry = this.index.get(key);
      if (!entry) {
        continue;
      }
      try {
        if (fs.accessSync(this.filePath(key))) {
          fs.unlinkSync(this.filePath(key));
        }
      } catch (err) {
      }
      total -= entry.size;
      this.index.delete(key);
      hilog.info(DOMAIN, TAG, 'evicted: %{public}s', key);
    }
    this.persistIndex();
  }
}
