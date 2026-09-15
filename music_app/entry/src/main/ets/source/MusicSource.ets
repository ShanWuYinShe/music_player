import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SongRecord } from '../model/Song';
import {
  OnlineCacheEntry, OnlineHealthInfo, OnlineProviderState, effectiveBaseUrl,
  healthUrl, isCacheFresh, parseOnlineCache, parseOnlineHealth,
  parseOnlineProviders, parseOnlineSongs, providersUrl, serializeOnlineCache,
  songsUrl
} from './OnlineApi';

/** 在线请求连接与读取超时（毫秒） */
const REQUEST_TIMEOUT_MS = 8000;

/** 在线列表缓存 TTL：热歌榜日更、服务器曲库低频变化，窗口内重复进入零网络 */
const LIST_CACHE_TTL_MS = 10 * 60 * 1000;
/** 内存缓存条目上限（含搜索查询），超出按插入序淘汰最旧 */
const MEM_CACHE_LIMIT = 8;
/** 默认视图（空查询）持久化文件（filesDir 下），杀进程重开仍可秒开 */
const PERSIST_FILE_NAME = 'online_list_cache.json';

/** 缓存命中结果：songs 为缓存列表，fresh=是否仍在 TTL 内（过期走静默刷新） */
export interface OnlineCacheHit {
  songs: SongRecord[];
  fresh: boolean;
}

/**
 * 在线音乐源：
 * 对接同仓库 music_server 的 GET /songs（列表/搜索）与 GET /stream/{id}
 * （Range 流式播放）。地址由设置页配置并持久化（需含到 /api[/music] 前缀），
 * 留空回落默认线上服务（DEFAULT_ONLINE_BASE_URL）；响应解析见 OnlineApi.ets。
 *
 * 列表缓存（stale-while-revalidate）：成功结果进内存缓存（按查询词键控，
 * 来回切源秒开）；默认视图（空查询）同时持久化到 filesDir，杀进程重开也
 * 秒开。TTL 由调用方经 peekCache().fresh 判断，过期展示旧列表 + 静默刷新；
 * 服务地址变更整体失效。
 */
export class OnlineSource {
  /** 用户配置的服务地址（原始输入 trim），空串表示未配置（用默认） */
  configuredUrl: string = '';
  /** 在途列表查询句柄：新查询先 abort 旧的（latest-wins，弱网连点/清空
   * 抖动不堆连接；旧响应本就按代际号丢弃，中止只省流量） */
  private inflightSongs: http.HttpRequest | null = null;
  /** 沙箱 filesDir（AppStore.init 注入）；空串=未注入，持久化关闭 */
  private cacheDir: string = '';
  /** 列表内存缓存：key=trim 后查询词，'' 为默认视图 */
  private memCache: Map<string, OnlineCacheEntry> = new Map();

  /** 生效地址：配置值非空用它，否则默认服务地址（永不为空） */
  get baseUrl(): string {
    return effectiveBaseUrl(this.configuredUrl);
  }

  /** 注入沙箱目录并恢复持久化的默认视图缓存（AppStore.init 调用一次） */
  setCacheDir(filesDir: string): void {
    this.cacheDir = filesDir;
    try {
      const raw = fs.readTextSync(`${filesDir}/${PERSIST_FILE_NAME}`);
      const entry = parseOnlineCache(raw, this.baseUrl);
      if (entry !== null) {
        this.memCache.set('', entry);
      }
    } catch (err) {
      // 无缓存文件或损坏：按无缓存处理，走正常拉取
    }
  }

  /** 查列表缓存：未命中返回 null；命中带 fresh 标记供调用方决定静默刷新 */
  peekCache(query: string): OnlineCacheHit | null {
    this.invalidateIfBaseChanged();
    const entry = this.memCache.get(query.trim());
    if (entry === undefined) {
      return null;
    }
    return {
      songs: entry.songs,
      fresh: isCacheFresh(entry.savedAt, Date.now(), LIST_CACHE_TTL_MS)
    };
  }

  /** 服务地址变更即缓存整体失效（以任一条目 baseUrl 不一致为代表判断） */
  private invalidateIfBaseChanged(): void {
    for (const entry of this.memCache.values()) {
      if (entry.baseUrl !== this.baseUrl) {
        this.memCache.clear();
        return;
      }
    }
  }

  /** 成功结果入缓存（fetchSongs 成功后调用）：内存全查询，默认视图同时落盘 */
  private putCache(query: string, songs: SongRecord[]): void {
    this.invalidateIfBaseChanged();
    const key = query.trim();
    if (this.memCache.has(key)) {
      this.memCache.delete(key);
    }
    this.memCache.set(key, { baseUrl: this.baseUrl, savedAt: Date.now(), songs: songs });
    while (this.memCache.size > MEM_CACHE_LIMIT) {
      const oldest = this.memCache.keys().next();
      if (oldest.done) {
        break;
      }
      this.memCache.delete(oldest.value);
    }
    if (key === '' && this.cacheDir !== '') {
      try {
        const file = fs.openSync(`${this.cacheDir}/${PERSIST_FILE_NAME}`,
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd,
          serializeOnlineCache(this.memCache.get('') as OnlineCacheEntry));
        fs.closeSync(file);
      } catch (err) {
        // 缓存落盘失败不影响功能
      }
    }
  }

  /**
   * 拉取在线曲目列表：query 非空走服务端搜索（本地曲库匹配 + 网络源聚合），
   * 为空返回服务器曲库全量 + 网络源推荐（limit 上限 500）。网络/HTTP 失败抛
   * Error 由调用方提示。
   */
  async fetchSongs(query: string = ''): Promise<SongRecord[]> {
    if (this.inflightSongs !== null) {
      try {
        this.inflightSongs.destroy();
      } catch (err) {
      }
      this.inflightSongs = null;
    }
    const request = http.createHttp();
    this.inflightSongs = request;
    try {
      const response = await request.request(songsUrl(this.baseUrl, query), {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: REQUEST_TIMEOUT_MS,
        readTimeout: REQUEST_TIMEOUT_MS,
        usingCache: false
      });
      if (response.responseCode !== 200) {
        throw new Error(`服务异常 ${response.responseCode}`);
      }
      const list = parseOnlineSongs(this.baseUrl, `${response.result}`);
      this.putCache(query, list);
      return list;
    } finally {
      if (this.inflightSongs === request) {
        this.inflightSongs = null;
      }
      request.destroy();
    }
  }

  /**
   * 拉取源能力摘要（网易云源是否启用/已登录）：用于在线页「未登录仅试听」
   * 提示。网络/HTTP 失败抛 Error，调用方静默忽略（提示非关键路径）。
   */
  async fetchHealth(): Promise<OnlineHealthInfo> {
    const request = http.createHttp();
    try {
      const response = await request.request(healthUrl(this.baseUrl), {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: REQUEST_TIMEOUT_MS,
        readTimeout: REQUEST_TIMEOUT_MS,
        usingCache: false
      });
      if (response.responseCode !== 200) {
        throw new Error(`服务异常 ${response.responseCode}`);
      }
      const info = parseOnlineHealth(`${response.result}`);
      if (info === null) {
        throw new Error('health 响应解析失败');
      }
      return info;
    } finally {
      request.destroy();
    }
  }

  async fetchProviders(): Promise<OnlineProviderState> {
    const request = http.createHttp();
    try {
      const response = await request.request(providersUrl(this.baseUrl), {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: REQUEST_TIMEOUT_MS,
        readTimeout: REQUEST_TIMEOUT_MS,
        usingCache: false
      });
      if (response.responseCode !== 200) {
        throw new Error(`服务异常 ${response.responseCode}`);
      }
      const state = parseOnlineProviders(`${response.result}`);
      if (state === null) {
        throw new Error('providers 响应解析失败');
      }
      return state;
    } finally {
      request.destroy();
    }
  }
}
