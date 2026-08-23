import { http } from '@kit.NetworkKit';
import { SongRecord } from '../model/Song';
import { MusicLibrary } from '../library/MusicLibrary';
import { parseOnlineSongs, songsUrl, effectiveBaseUrl } from './OnlineApi';

/**
 * 音乐源抽象：本地导入与在线 API 的统一入口。
 * 本地为曲库同步实现；在线走异步拉取（fetchSongs），getSongs 返回缓存。
 */
export interface MusicSource {
  /** 源名称（用于 UI 展示） */
  readonly name: string;
  /** 是否具备在线能力（决定设置页是否展示配置项） */
  readonly online: boolean;
  /** 获取曲目列表 */
  getSongs(): SongRecord[];
}

/**
 * 本地音乐源：包装 MusicLibrary
 */
export class LocalSource implements MusicSource {
  readonly name: string = '本地音乐';
  readonly online: boolean = false;

  private library: MusicLibrary;

  constructor(library: MusicLibrary) {
    this.library = library;
  }

  getSongs(): SongRecord[] {
    return this.library.getAllSongs();
  }
}

/**
 * 在线音乐源：
 * 对接同仓库 music_server 的 GET /songs（列表/搜索）与 GET /stream/{id}
 * （Range 流式播放）。地址由设置页配置并持久化（需含到 /api[/music] 前缀），
 * 留空回落默认线上服务（DEFAULT_ONLINE_BASE_URL）；响应解析见 OnlineApi.ets。
 */
export class OnlineSource implements MusicSource {
  readonly name: string = '在线音乐';
  readonly online: boolean = true;

  /** 用户配置的服务地址（原始输入 trim），空串表示未配置（用默认） */
  configuredUrl: string = '';
  /** 最近一次成功拉取的曲目缓存 */
  private cache: SongRecord[] = [];

  /** 生效地址：配置值非空用它，否则默认服务地址（永不为空） */
  get baseUrl(): string {
    return effectiveBaseUrl(this.configuredUrl);
  }

  getSongs(): SongRecord[] {
    return this.cache;
  }

  /**
   * 拉取在线曲目列表（全量，服务端 limit 上限 500）：
   * 网络/HTTP 失败抛 Error 由调用方提示。
   */
  async fetchSongs(): Promise<SongRecord[]> {
    const request = http.createHttp();
    try {
      const response = await request.request(songsUrl(this.baseUrl), {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 8000,
        usingCache: false
      });
      if (response.responseCode !== 200) {
        throw new Error(`服务端响应 ${response.responseCode}`);
      }
      const songs = parseOnlineSongs(this.baseUrl, `${response.result}`);
      this.cache = songs;
      return songs;
    } finally {
      request.destroy();
    }
  }
}
