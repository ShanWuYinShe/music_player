import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

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
 * 登录后试听字节污染完整音频），本类只管存取与 LRU 淘汰。
 */
export class OnlineCache {
  private dir: string = '';
  private index: Map<string, CacheEntry> = new Map<string, CacheEntry>();
  /** 正在后台下载的 key（防重复下载；切歌取消后移出） */
  private inflight: Set<string> = new Set<string>();
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

  /**
   * 后台整曲下载：播放同时存盘，下次复播命中。
   * shouldContinue 在每个分片回调检查——切歌后旧下载中止并删除半成品，
   * 不浪费流量；下载失败静默（仅打日志），不影响当前播放。
   */
  prefetch(songId: string, url: string, shouldContinue: () => boolean): void {
    if (this.dir === '' || this.index.has(songId) || this.inflight.has(songId)) {
      return;
    }
    this.inflight.add(songId);
    const path = this.filePath(songId);
    let fd = -1;
    let done = false;
    const request = http.createHttp();
    const finish = (success: boolean): void => {
      if (done) {
        return;
      }
      done = true;
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
        return;
      }
      try {
        const size = fs.statSync(path).size;
        if (size <= 0) {
          fs.unlinkSync(path);
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
    };
    try {
      fd = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC).fd;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'open cache file failed: %{public}s', JSON.stringify(err));
      finish(false);
      return;
    }
    request.on('dataReceive', (buf: ArrayBuffer) => {
      if (!shouldContinue()) {
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
      finish(shouldContinue());
    });
    try {
      request.requestInStream(url, {
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

  /** 缓存文件名：id 含 online:/斜杠等非法字符，转义后加统一后缀 */
  private filePath(songId: string): string {
    const safe = songId.replace(/[^a-zA-Z0-9_-]/g, '_');
    return `${this.dir}/${safe}.audio`;
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

  /** 对账：删孤儿文件（在盘不在索引）、丢过期索引（在索引不在盘）、超限淘汰 */
  private reconcile(): void {
    try {
      const names = new Set<string>(fs.listFileSync(this.dir));
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

  /** LRU 淘汰到上限内（在途下载不计入、不淘汰） */
  private evictIfNeeded(): void {
    let total = 0;
    for (const key of this.index.keys()) {
      const entry = this.index.get(key);
      if (entry) {
        total += entry.size;
      }
    }
    if (total <= MAX_CACHE_BYTES) {
      return;
    }
    const ordered: string[] = [];
    for (const key of this.index.keys()) {
      if (!this.inflight.has(key)) {
        ordered.push(key);
      }
    }
    ordered.sort((a, b) => {
      const ea = this.index.get(a);
      const eb = this.index.get(b);
      return (ea ? ea.lastAccess : 0) - (eb ? eb.lastAccess : 0);
    });
    for (const key of ordered) {
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
