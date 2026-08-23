import { SongRecord } from '../model/Song';
import { MusicLibrary } from '../library/MusicLibrary';

/**
 * 音乐源抽象：本地导入与在线 API 的统一入口。
 * 本期为本地实现；在线源预留接口，接入时实现 OnlineSource 即可。
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
 * 在线音乐源（预留骨架）：
 * 对接同仓库 music_server（providers/songs/stream API），Base URL 由设置页配置。
 * 接入时实现 search/getSongs 并将结果映射为 SongRecord（fileName 存 stream URL，
 * PlayerController 需按 online 标记走网络播放分支）。
 */
export class OnlineSource implements MusicSource {
  readonly name: string = '在线音乐';
  readonly online: boolean = true;

  /** 服务端 Base URL，空表示未配置 */
  baseUrl: string = '';

  getSongs(): SongRecord[] {
    // TODO: 接入在线 API 后返回真实曲目
    return [];
  }
}
