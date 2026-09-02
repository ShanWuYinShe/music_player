import { http } from '@kit.NetworkKit';
import { SongRecord } from '../model/Song';
import { OnlineProviderState, parseOnlineProviders, parseOnlineSongs, providersUrl, songsUrl, effectiveBaseUrl } from './OnlineApi';

/** 在线请求连接与读取超时（毫秒） */
const REQUEST_TIMEOUT_MS = 8000;

/**
 * 在线音乐源：
 * 对接同仓库 music_server 的 GET /songs（列表/搜索）与 GET /stream/{id}
 * （Range 流式播放）。地址由设置页配置并持久化（需含到 /api[/music] 前缀），
 * 留空回落默认线上服务（DEFAULT_ONLINE_BASE_URL）；响应解析见 OnlineApi.ets。
 */
export class OnlineSource {
  /** 用户配置的服务地址（原始输入 trim），空串表示未配置（用默认） */
  configuredUrl: string = '';

  /** 生效地址：配置值非空用它，否则默认服务地址（永不为空） */
  get baseUrl(): string {
    return effectiveBaseUrl(this.configuredUrl);
  }

  /**
   * 拉取在线曲目列表：query 非空走服务端搜索（本地曲库匹配 + 网络源聚合），
   * 为空返回服务器曲库全量 + 网络源推荐（limit 上限 500）。网络/HTTP 失败抛
   * Error 由调用方提示。
   */
  async fetchSongs(query: string = ''): Promise<SongRecord[]> {
    const request = http.createHttp();
    try {
      const response = await request.request(songsUrl(this.baseUrl, query), {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: REQUEST_TIMEOUT_MS,
        readTimeout: REQUEST_TIMEOUT_MS,
        usingCache: false
      });
      if (response.responseCode !== 200) {
        throw new Error(`服务端响应 ${response.responseCode}`);
      }
      return parseOnlineSongs(this.baseUrl, `${response.result}`);
    } finally {
      request.destroy();
    }
  }

  /**
   * 拉取源能力摘要（网易云源是否启用/已登录）：用于在线页「未登录仅试听」
   * 提示。网络/HTTP 失败抛 Error，调用方静默忽略（提示非关键路径）。
   */
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
        throw new Error(`服务端响应 ${response.responseCode}`);
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
