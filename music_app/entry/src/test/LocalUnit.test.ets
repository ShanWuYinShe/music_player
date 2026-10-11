import { describe, it, expect } from '@ohos/hypium';
import { PlayMode, nextPlayMode, playModeLabel, shouldRestartAtHead, RESTART_AT_HEAD_MS } from '../main/ets/model/PlayMode';
import { formatTime, formatTotalDuration } from '../main/ets/common/TimeUtils';
import { SongRecord } from '../main/ets/model/Song';
import { LibraryTab, SortMode, filterAndSort, sortLabel, splitHighlight, TextSegment } from '../main/ets/common/LibraryFilter';
import {
  ONLINE_ID_PREFIX, normalizeBaseUrl, effectiveBaseUrl, DEFAULT_ONLINE_BASE_URL,
  songsUrl, providersUrl, parseOnlineSongs, parseOnlineProviders,
  OnlineSongItem, OnlineSongsResponse,
  OnlineCacheEntry, isCacheFresh, serializeOnlineCache, parseOnlineCache,
  isOnlineId, onlineItemId, rebuildStreamUrl,
  serializeOnlineSongStore, parseOnlineSongStore, evictOrder, CacheEntryLike,
  parseOnlineHealth, healthUrl
} from '../main/ets/source/OnlineApi';
import { firstGlyph } from '../main/ets/common/TextFormat';
import { classifyStrokeEnd, earlyClassifyStroke } from '../main/ets/common/GesturePath';
import {
  PRESET_COUNT, VIZ_PRESET_NAMES, seedFromId, synthSpectrum,
  beatEnvelope, bpmFromSeed, hslToRgb, normalizeTilt,
  normalizeSpin, wrapAngleDelta, accelKickLevel
} from '../main/ets/common/VisualizerCore';
import { parseTlenMs } from '../main/ets/library/Id3ParserCore';
import { parseFileNameMeta, LOCAL_ARTIST_FALLBACK } from '../main/ets/library/FileNameMeta';
import { cacheFileName, CACHE_FILE_SUFFIX, CACHE_INDEX_FILE } from '../main/ets/player/CacheFileName';
import { fftMagnitudes, isPowerOfTwo } from '../main/ets/common/Fft';

/** 构造测试歌曲记录 */
function mk(id: string, title: string, artist: string, duration: number): SongRecord {
  return {
    id: id,
    title: title,
    artist: artist,
    album: '',
    duration: duration,
    fileName: `${id}.mp3`,
    coverPath: ''
  };
}

/** 逐通道断言 RGB 数组 */
function expectRgb(rgb: number[], r: number, g: number, b: number): void {
  expect(rgb[0]).assertEqual(r);
  expect(rgb[1]).assertEqual(g);
  expect(rgb[2]).assertEqual(b);
}

/** 构造在线列表缓存条目（曲目用既有 mk 助手保证字段完整） */
function mkEntry(baseUrl: string, savedAt: number): OnlineCacheEntry {
  const songs: SongRecord[] = [mk('online:1', '雨后琶音', '湖畔晚风', 18000)];
  return { baseUrl: baseUrl, savedAt: savedAt, songs: songs };
}

/** 构造注册表在线歌曲记录（fileName 为流地址，还原/补位测试共用） */
function mkOnline(itemId: string, title: string): SongRecord {
  return {
    id: `online:${itemId}`,
    title: title,
    artist: '湖畔晚风',
    album: '',
    duration: 240000,
    fileName: `http://h/api/music/stream/${itemId}`,
    coverPath: ''
  };
}

/** evictOrder 测试用条目形态（满足 CacheEntryLike） */
interface TestCacheEntry {
  size: number;
  lastAccess: number;
}

export default function LocalUnitSuite() {
  describe('PlayModeTest', () => {
    it('cycleShouldCoverAllModes', 0, () => {
      expect(nextPlayMode(PlayMode.SEQUENCE)).assertEqual(PlayMode.SINGLE);
      expect(nextPlayMode(PlayMode.SINGLE)).assertEqual(PlayMode.SHUFFLE);
      expect(nextPlayMode(PlayMode.SHUFFLE)).assertEqual(PlayMode.SEQUENCE);
    });
    it('labelShouldMatchMode', 0, () => {
      expect(playModeLabel(PlayMode.SEQUENCE)).assertEqual('顺序播放');
      expect(playModeLabel(PlayMode.SINGLE)).assertEqual('单曲循环');
      expect(playModeLabel(PlayMode.SHUFFLE)).assertEqual('随机播放');
    });
    // 「上一首只回曲首」判据：previous()(执行) 与 peekPrevCover()(预览) 共用。
    // 预览若少看 hasLoadedPlayer 条件,冷启动续播态会「实际切了歌却回弹」。
    it('restartAtHeadRequiresLoadedPlayer', 0, () => {
      expect(RESTART_AT_HEAD_MS).assertEqual(5000);
      // 播超 5 秒 + 已加载 → 回曲首
      expect(shouldRestartAtHead(5001, true)).assertTrue();
      expect(shouldRestartAtHead(60000, true)).assertTrue();
      // 未过 5 秒 → 切上一首(与 player 是否已加载无关)
      expect(shouldRestartAtHead(5000, true)).assertFalse();
      expect(shouldRestartAtHead(0, true)).assertFalse();
      // 关键:播超 5 秒但 player 未建(冷启动续播态)→ 必须切上一首,不能回曲首
      expect(shouldRestartAtHead(60000, false)).assertFalse();
      expect(shouldRestartAtHead(5001, false)).assertFalse();
    });
  });

  describe('TimeUtilsTest', () => {
    it('formatZeroAndNegative', 0, () => {
      expect(formatTime(0)).assertEqual('00:00');
      expect(formatTime(-100)).assertEqual('00:00');
    });
    it('formatMinutesSeconds', 0, () => {
      expect(formatTime(59000)).assertEqual('00:59');
      expect(formatTime(60000)).assertEqual('01:00');
      expect(formatTime(754000)).assertEqual('12:34');
    });
    it('formatTotalDurationBuckets', 0, () => {
      expect(formatTotalDuration(0)).assertEqual('0 分钟');
      expect(formatTotalDuration(-5)).assertEqual('0 分钟');
      expect(formatTotalDuration(59000)).assertEqual('不足 1 分钟'); // 小于 1 分钟有明确文案
      expect(formatTotalDuration(55000)).assertEqual('不足 1 分钟');
      expect(formatTotalDuration(60000 * 45)).assertEqual('45 分钟');
      expect(formatTotalDuration(60000 * 60)).assertEqual('1 小时');
      expect(formatTotalDuration(60000 * 95)).assertEqual('1 小时 35 分钟');
    });
  });

  describe('LibraryFilterTest', () => {
    const songs: SongRecord[] = [
      mk('a', '晨光旋律', '远山晨雾', 200000),
      mk('b', '温柔节拍', '拾光者', 150000),
      mk('c', '雨后琶音', '湖畔晚风', 300000),
      mk('d', '夜色钢琴', '', 0)
    ];

    it('queryFiltersTitleArtistAlbumCaseInsensitive', 0, () => {
      const result = filterAndSort(songs, {
        query: '拾光',
        tab: LibraryTab.ALL,
        sort: SortMode.DEFAULT,
        favoriteIds: [],
        recentIds: []
      });
      expect(result.length).assertEqual(1);
      expect(result[0].id).assertEqual('b');
      // 大小写不敏感：大写查询词命中英文标题
      const byLatin = filterAndSort([mk('e', 'Golden Hour', 'Nova', 90000)].concat(songs), {
        query: 'GOLDEN',
        tab: LibraryTab.ALL,
        sort: SortMode.DEFAULT,
        favoriteIds: [],
        recentIds: []
      });
      expect(byLatin.length).assertEqual(1);
      expect(byLatin[0].id).assertEqual('e');
    });

    it('favoritesTabKeepsNewestFirstOrder', 0, () => {
      const result = filterAndSort(songs, {
        query: '',
        tab: LibraryTab.FAVORITES,
        sort: SortMode.DEFAULT,
        favoriteIds: ['a', 'c'],
        recentIds: []
      });
      expect(result.length).assertEqual(2);
      expect(result[0].id).assertEqual('c'); // 最新收藏在前
      expect(result[1].id).assertEqual('a');
    });

    it('recentTabFollowsRecencyAndSkipsDeleted', 0, () => {
      const result = filterAndSort(songs, {
        query: '',
        tab: LibraryTab.RECENT,
        sort: SortMode.DEFAULT,
        favoriteIds: [],
        recentIds: ['zz', 'b', 'a']
      });
      expect(result.length).assertEqual(2); // zz 已不存在，跳过
      expect(result[0].id).assertEqual('b');
      expect(result[1].id).assertEqual('a');
    });

    it('sortDurationUnknownGoesLast', 0, () => {
      const result = filterAndSort(songs, {
        query: '',
        tab: LibraryTab.ALL,
        sort: SortMode.DURATION,
        favoriteIds: [],
        recentIds: []
      });
      expect(result.length).assertEqual(4);
      expect(result[0].id).assertEqual('c');
      expect(result[1].id).assertEqual('a');
      expect(result[2].id).assertEqual('b');
      expect(result[3].id).assertEqual('d'); // 时长未知排最后
    });

    it('sortArtistThenTitle', 0, () => {
      // 歌手名用 ASCII:LocalUnit(Node)环境 localeCompare 对中文退化为
      // 码点序(乙 U+4E59 < 甲 U+7532),拼音排序假设不成立
      const list: SongRecord[] = [
        mk('x', 'B歌', 'artist2', 1000),
        mk('y', 'A歌', 'artist1', 1000),
        mk('z', 'A歌', 'artist2', 1000)
      ];
      const result = filterAndSort(list, {
        query: '',
        tab: LibraryTab.ALL,
        sort: SortMode.ARTIST,
        favoriteIds: [],
        recentIds: []
      });
      expect(result[0].id).assertEqual('y'); // artist1·A歌
      expect(result[1].id).assertEqual('z'); // artist2·A歌
      expect(result[2].id).assertEqual('x'); // artist2·B歌
    });

    it('emptyLibraryReturnsEmpty', 0, () => {
      const result = filterAndSort([], {
        query: 'anything',
        tab: LibraryTab.ALL,
        sort: SortMode.DEFAULT,
        favoriteIds: [],
        recentIds: []
      });
      expect(result.length).assertEqual(0);
    });

    it('favoritesTabFillsOnlineSongsFromRegistry', 0, () => {
      // 收藏含本地与在线 id：在线歌从注册表补位，按收藏时间倒序混排
      const registry: SongRecord[] = [mkOnline('n1', '云端序曲'), mkOnline('n2', '云端夜航')];
      const result = filterAndSort(songs, {
        query: '',
        tab: LibraryTab.FAVORITES,
        sort: SortMode.DEFAULT,
        favoriteIds: ['a', 'online:n1', 'c'],
        recentIds: [],
        onlineSongs: registry
      });
      expect(result.length).assertEqual(3);
      expect(result[0].id).assertEqual('c'); // favoriteIds 末尾=最新收藏在前
      expect(result[1].id).assertEqual('online:n1');
      expect(result[1].title).assertEqual('云端序曲');
      expect(result[1].fileName).assertEqual('http://h/api/music/stream/n1');
      expect(result[2].id).assertEqual('a');
      // 注册表也找不到的收藏 id 依旧跳过
      const missing = filterAndSort(songs, {
        query: '',
        tab: LibraryTab.FAVORITES,
        sort: SortMode.DEFAULT,
        favoriteIds: ['online:gone'],
        recentIds: [],
        onlineSongs: registry
      });
      expect(missing.length).assertEqual(0);
    });

    it('recentTabFillsOnlineSongsAndQueryFiltersThem', 0, () => {
      const registry: SongRecord[] = [mkOnline('n1', '云端序曲'), mkOnline('n2', '云端夜航')];
      const result = filterAndSort(songs, {
        query: '',
        tab: LibraryTab.RECENT,
        sort: SortMode.DEFAULT,
        favoriteIds: [],
        recentIds: ['b', 'online:n2', 'online:n1'],
        onlineSongs: registry
      });
      expect(result.length).assertEqual(3);
      expect(result[0].id).assertEqual('b'); // recentIds 顺序=最新播放在前
      expect(result[1].id).assertEqual('online:n2');
      expect(result[2].id).assertEqual('online:n1');
      // 查询词过滤对补位的在线歌同样生效
      const filtered = filterAndSort(songs, {
        query: '夜航',
        tab: LibraryTab.RECENT,
        sort: SortMode.DEFAULT,
        favoriteIds: [],
        recentIds: ['b', 'online:n2', 'online:n1'],
        onlineSongs: registry
      });
      expect(filtered.length).assertEqual(1);
      expect(filtered[0].id).assertEqual('online:n2');
    });

    it('allTabExcludesOnlineSongs', 0, () => {
      // 全部 Tab 只列本地曲库，注册表条目不混入
      const result = filterAndSort(songs, {
        query: '',
        tab: LibraryTab.ALL,
        sort: SortMode.DEFAULT,
        favoriteIds: ['online:n1'],
        recentIds: [],
        onlineSongs: [mkOnline('n1', '云端序曲')]
      });
      expect(result.length).assertEqual(songs.length);
    });
  });

  describe('OnlineApiTest', () => {
    const item1: OnlineSongItem = {
      id: 'a1b2c3d4e5f60718', title: '晴天', artist: '周杰伦',
      album: '叶惠美', durationMs: 0, format: 'mp3', sizeBytes: 1024
    };
    const item2: OnlineSongItem = { id: 'b266199c9eea8d0b', title: '江南', durationMs: 269000 };
    const response: OnlineSongsResponse = { songs: [item1, item2], total: 2 };
    const BODY = JSON.stringify(response);

    it('normalizeBaseUrlTrimsTrailingSlashes', 0, () => {
      expect(normalizeBaseUrl('  http://10.0.2.2:8790/api/  ')).assertEqual('http://10.0.2.2:8790/api');
      expect(normalizeBaseUrl('')).assertEqual('');
      expect(normalizeBaseUrl('///')).assertEqual('');
    });

    it('effectiveBaseUrlFallsBackToDefault', 0, () => {
      // 留空/纯空白/纯斜杠 → 默认线上服务地址
      expect(effectiveBaseUrl('')).assertEqual(DEFAULT_ONLINE_BASE_URL);
      expect(effectiveBaseUrl('   ')).assertEqual(DEFAULT_ONLINE_BASE_URL);
      expect(effectiveBaseUrl('///')).assertEqual(DEFAULT_ONLINE_BASE_URL);
      // 配置值非空 → 规范化后原样使用
      expect(effectiveBaseUrl('http://10.0.2.2:8790/api/')).assertEqual('http://10.0.2.2:8790/api');
    });

    it('songsUrlJoinsPath', 0, () => {
      expect(songsUrl('http://host/api/music/')).assertEqual('http://host/api/music/songs');
    });

    it('songsUrlAppendsEncodedQuery', 0, () => {
      expect(songsUrl('http://h/api/music', '晴天')).assertEqual('http://h/api/music/songs?q=%E6%99%B4%E5%A4%A9');
      expect(songsUrl('http://h/api/music', '  ')).assertEqual('http://h/api/music/songs');
    });

    it('parseMapsIdTitleAndStreamUrl', 0, () => {
      const list = parseOnlineSongs('http://host/api/music', BODY);
      expect(list.length).assertEqual(2);
      expect(list[0].id).assertEqual(`${ONLINE_ID_PREFIX}a1b2c3d4e5f60718`);
      expect(list[0].fileName).assertEqual('http://host/api/music/stream/a1b2c3d4e5f60718');
      expect(list[0].title).assertEqual('晴天');
      expect(list[0].artist).assertEqual('周杰伦');
      expect(list[0].album).assertEqual('叶惠美');
    });

    it('parseFillsOptionalFields', 0, () => {
      const list = parseOnlineSongs('http://h/api', BODY);
      // 服务端省略 artist/album 时映射为空串，durationMs 正常透传
      expect(list[1].artist).assertEqual('');
      expect(list[1].album).assertEqual('');
      expect(list[1].duration).assertEqual(269000);
    });

    it('parseRejectsInvalidInput', 0, () => {
      expect(parseOnlineSongs('http://h/api', '').length).assertEqual(0);
      expect(parseOnlineSongs('http://h/api', 'not json').length).assertEqual(0);
      expect(parseOnlineSongs('http://h/api', '{"total":0}').length).assertEqual(0);
      // 未配置 Base URL 直接返回空
      expect(parseOnlineSongs('', BODY).length).assertEqual(0);
    });

    it('parseMapsFormatAndVip', 0, () => {
      const vipItem1: OnlineSongItem = { id: 'ne_111', title: 'VIP歌', format: 'mp3', vip: true };
      const vipItem2: OnlineSongItem = { id: 'ne_222', title: '免费歌', format: 'flac', vip: false };
      const vipItem3: OnlineSongItem = { id: 'ne_333', title: '省略字段' };
      const vipBody = JSON.stringify({ songs: [vipItem1, vipItem2, vipItem3], total: 3 });
      const list = parseOnlineSongs('http://h/api/music', vipBody);
      expect(list[0].format).assertEqual('MP3');
      expect(list[0].vip).assertTrue();
      expect(list[1].format).assertEqual('FLAC');
      expect(list[1].vip).assertUndefined();
      expect(list[2].format).assertUndefined();
      expect(list[2].vip).assertUndefined();
    });

    it('providersUrlJoinsPath', 0, () => {
      expect(providersUrl('http://host/api/music/')).assertEqual('http://host/api/music/providers');
    });

    it('parseOnlineProvidersStates', 0, () => {
      // netease 存在且已登录
      const loggedIn = parseOnlineProviders('{"providers":[{"id":"library"},{"id":"netease","loggedIn":true}]}');
      if (loggedIn === null) {
        expect(false).assertTrue();
      } else {
        expect(loggedIn.neteaseLoggedIn).assertTrue();
      }
      // netease 存在但未登录（loggedIn 缺省视为 false）
      const anon = parseOnlineProviders('{"providers":[{"id":"library"},{"id":"netease"}]}');
      if (anon === null) {
        expect(false).assertTrue();
      } else {
        expect(anon.neteaseLoggedIn).assertFalse();
      }
      // 无 netease 源：等价未登录
      const localOnly = parseOnlineProviders('{"providers":[{"id":"library"}]}');
      if (localOnly === null) {
        expect(false).assertTrue();
      } else {
        expect(localOnly.neteaseLoggedIn).assertFalse();
      }
      // 非法响应返回 null
      expect(parseOnlineProviders('')).assertNull();
      expect(parseOnlineProviders('not json')).assertNull();
      expect(parseOnlineProviders('{}')).assertNull();
    });
  });

  describe('OnlineSongStoreApiTest', () => {
    it('onlineIdHelpers', 0, () => {
      expect(isOnlineId('online:a1b2')).assertTrue();
      expect(isOnlineId('demo01.mp3')).assertFalse();
      expect(onlineItemId('online:a1b2')).assertEqual('a1b2');
      expect(onlineItemId('demo01.mp3')).assertEqual('');
    });

    it('rebuildStreamUrlJoinsPath', 0, () => {
      expect(rebuildStreamUrl('http://h/api/music/', 'n1')).assertEqual('http://h/api/music/stream/n1');
      expect(rebuildStreamUrl('http://h/api/music', 'n1')).assertEqual('http://h/api/music/stream/n1');
    });

    it('songStoreRoundTripKeepsFields', 0, () => {
      const song = mkOnline('n1', '云端序曲');
      song.format = 'FLAC';
      song.vip = true;
      const restored = parseOnlineSongStore(
        serializeOnlineSongStore('http://h/api/music', [song]), 'http://h/api/music');
      if (restored === null) {
        expect(false).assertTrue();
        return;
      }
      expect(restored.length).assertEqual(1);
      expect(restored[0].id).assertEqual('online:n1');
      expect(restored[0].title).assertEqual('云端序曲');
      expect(restored[0].artist).assertEqual('湖畔晚风');
      expect(restored[0].duration).assertEqual(240000);
      expect(restored[0].fileName).assertEqual('http://h/api/music/stream/n1');
      expect(restored[0].format).assertEqual('FLAC');
      expect(restored[0].vip).assertTrue();
    });

    it('songStoreRebuildsUrlOnBaseUrlChange', 0, () => {
      // 换服务地址后流地址重拼为新服，其余字段不变
      const restored = parseOnlineSongStore(
        serializeOnlineSongStore('http://old/api/music', [mkOnline('n1', '云端序曲')]),
        'http://new/api/music');
      if (restored === null) {
        expect(false).assertTrue();
        return;
      }
      expect(restored.length).assertEqual(1);
      expect(restored[0].fileName).assertEqual('http://new/api/music/stream/n1');
      expect(restored[0].title).assertEqual('云端序曲');
    });

    it('songStoreRejectsInvalidInput', 0, () => {
      expect(parseOnlineSongStore('', 'http://h/api')).assertNull();
      expect(parseOnlineSongStore('not json', 'http://h/api')).assertNull();
      // 缺 version 字段（旧文件形态）拒绝
      expect(parseOnlineSongStore('{"baseUrl":"http://h/api","songs":[]}', 'http://h/api')).assertNull();
      // 缺 baseUrl 拒绝
      expect(parseOnlineSongStore('{"version":1,"songs":[]}', 'http://h/api')).assertNull();
      // 条目过滤：非在线 id / 缺 title 的条目跳过，合法条目保留
      const localSong = mk('a', '本地歌', '', 1000);
      const noTitle: SongRecord = {
        id: 'online:x', title: '', artist: '', album: '', duration: 0,
        fileName: 'http://h/api/music/stream/x', coverPath: ''
      };
      const body = serializeOnlineSongStore('http://h/api', [localSong, noTitle, mkOnline('n1', '云端序曲')]);
      const restored = parseOnlineSongStore(body, 'http://h/api');
      if (restored === null) {
        expect(false).assertTrue();
        return;
      }
      expect(restored.length).assertEqual(1);
      expect(restored[0].id).assertEqual('online:n1');
    });

    it('evictOrderPrefersOldestNonPinned', 0, () => {
      const entries = new Map<string, TestCacheEntry>();
      entries.set('a', { size: 10, lastAccess: 100 });
      entries.set('b', { size: 10, lastAccess: 50 }); // 最旧但在途
      entries.set('c', { size: 10, lastAccess: 20 }); // 钉住
      entries.set('d', { size: 10, lastAccess: 300 });
      const pinned = new Set<string>(['c']);
      const skip = new Set<string>(['b']);
      // 在途跳过；非钉住按 lastAccess 升序在前；钉住垫后（即便更旧）
      const order = evictOrder(entries, pinned, skip);
      expect(order.join(',')).assertEqual('a,d,c');
    });

    it('evictOrderFallsBackToPinnedWhenAllPinned', 0, () => {
      // 全员钉住仍超限时，钉住内部按 lastAccess 升序兜底（磁盘硬上限）
      const entries = new Map<string, TestCacheEntry>();
      entries.set('p1', { size: 10, lastAccess: 5 });
      entries.set('p2', { size: 10, lastAccess: 9 });
      entries.set('p3', { size: 10, lastAccess: 7 });
      const order = evictOrder(entries, new Set<string>(['p1', 'p2', 'p3']), new Set<string>());
      expect(order.join(',')).assertEqual('p1,p3,p2');
    });
  });

  describe('Id3TlenTest', () => {
    it('parseTlenMsAcceptsPlainDigits', 0, () => {
      expect(parseTlenMs('230530')).assertEqual(230530);
      expect(parseTlenMs('0')).assertEqual(0);
    });
    it('parseTlenMsStripsNoiseAndBounded', 0, () => {
      expect(parseTlenMs('  12345 ')).assertEqual(12345);
      expect(parseTlenMs('abc12def3')).assertEqual(123);
      // 超 24h 视为非法
      expect(parseTlenMs(`${24 * 3600 * 1000}`)).assertEqual(0);
      expect(parseTlenMs(`${24 * 3600 * 1000 - 1}`)).assertEqual(24 * 3600 * 1000 - 1);
    });
    it('parseTlenMsRejectsInvalid', 0, () => {
      expect(parseTlenMs('')).assertEqual(0);
      expect(parseTlenMs('abc')).assertEqual(0);
      expect(parseTlenMs('-500')).assertEqual(0);
    });
  });

  describe('VisualizerCoreTest', () => {
    it('normalizeTiltDeadzoneAndSaturation', 0, () => {
      // 轴语义：x=gamma（左右横滚→水平），y=beta（前后俯仰→垂直）
      expect(normalizeTilt(40, 0)[0]).assertEqual(0);
      expect(normalizeTilt(40, 0)[1]).assertEqual(1);
      expect(normalizeTilt(0, 40)[0]).assertEqual(1);
      expect(normalizeTilt(0, 40)[1]).assertEqual(0);
      // 死区内（|deg| <= 4）恒 0
      expect(normalizeTilt(0, 0)[0]).assertEqual(0);
      expect(normalizeTilt(3.9, -2)[0]).assertEqual(0);
      expect(normalizeTilt(0, 4.0)[1]).assertEqual(0);
      // 过死区连续：4.1 度只留极小残量
      const just = normalizeTilt(4.1, 0)[1];
      expect(just > 0).assertTrue();
      expect(just < 0.01).assertTrue();
      // 满量程 ±40 度 = ±1，超过饱和
      expect(normalizeTilt(40, -40)[0]).assertEqual(-1);
      expect(normalizeTilt(40, -40)[1]).assertEqual(1);
      expect(normalizeTilt(120, -900)[0]).assertEqual(-1);
      expect(normalizeTilt(120, -900)[1]).assertEqual(1);
      // 中段线性：gamma 22 度 = (22-4)/36 ≈ 0.5
      const mid = normalizeTilt(0, 22)[0];
      expect(mid > 0.49 && mid < 0.51).assertTrue();
      // 非法输入归零（且 beta 通道不 leaking 到 x）
      expect(normalizeTilt(10, NaN)[0]).assertEqual(0);
      expect(normalizeTilt(NaN, NaN)[1]).assertEqual(0);
    });

    it('wrapAngleDeltaHandlesCompassWrap', 0, () => {
      // 0/360 回绕：359→1 只差 +2 度，不是 -358
      expect(wrapAngleDelta(1, 359)).assertEqual(2);
      expect(wrapAngleDelta(359, 1)).assertEqual(-2);
      expect(wrapAngleDelta(180, 0)).assertEqual(180);
      expect(wrapAngleDelta(0, 180)).assertEqual(180);
      expect(wrapAngleDelta(45, 30)).assertEqual(15);
      // 非法输入归零
      expect(wrapAngleDelta(NaN, 30)).assertEqual(0);
    });

    it('normalizeSpinDeadzoneAndSaturation', 0, () => {
      // 死区 ±5° 内恒 0
      expect(normalizeSpin(0)).assertEqual(0);
      expect(normalizeSpin(-5)).assertEqual(0);
      expect(normalizeSpin(5)).assertEqual(0);
      // 过死区连续
      const just = normalizeSpin(5.6);
      expect(just > 0).assertTrue();
      expect(just < 0.05).assertTrue();
      // 满量程 ±60° = ±1，超过饱和
      expect(normalizeSpin(60)).assertEqual(1);
      expect(normalizeSpin(-60)).assertEqual(-1);
      expect(normalizeSpin(200)).assertEqual(1);
      expect(normalizeSpin(-200)).assertEqual(-1);
      // 中段线性：32.5° = (32.5-5)/55 = 0.5
      const mid = normalizeSpin(32.5);
      expect(mid > 0.49 && mid < 0.51).assertTrue();
      expect(normalizeSpin(NaN)).assertEqual(0);
    });

    it('accelKickLevelThresholdAndSaturation', 0, () => {
      // 阈值 1.5 以下恒 0（日常手持抖动不起脉冲）
      expect(accelKickLevel(0, 0, 0)).assertEqual(0);
      expect(accelKickLevel(1.5, 0, 0)).assertEqual(0);
      expect(accelKickLevel(0.8, 0.8, 0.8)).assertEqual(0);
      // 过阈值连续：1.6 起微量
      const just = accelKickLevel(1.6, 0, 0);
      expect(just > 0).assertTrue();
      expect(just < 0.05).assertTrue();
      // 阈值 + 满量程（1.5+8=9.5）达 1，超过饱和
      expect(accelKickLevel(9.5, 0, 0)).assertEqual(1);
      expect(accelKickLevel(0, 20, 0)).assertEqual(1);
      // 中段线性：(5.5-1.5)/8 = 0.5
      const mid = accelKickLevel(0, 0, 5.5);
      expect(mid > 0.49 && mid < 0.51).assertTrue();
      // 非法输入归零
      expect(accelKickLevel(NaN, 0, 0)).assertEqual(0);
    });

    it('seedIsDeterministicAndDistinct', 0, () => {
      expect(seedFromId('song-a')).assertEqual(seedFromId('song-a'));
      expect(seedFromId('song-a')).not().assertEqual(seedFromId('song-b'));
    });

    it('spectrumLengthAndRange', 0, () => {
      const bars = synthSpectrum(123, 5000, 32);
      expect(bars.length).assertEqual(32);
      for (let i = 0; i < bars.length; i++) {
        expect(bars[i] > 0).assertTrue();
        expect(bars[i] <= 1).assertTrue();
      }
    });

    it('spectrumIsDeterministicAndSeedSensitive', 0, () => {
      const a1 = synthSpectrum(1, 4321, 16);
      const a2 = synthSpectrum(1, 4321, 16);
      const b = synthSpectrum(2, 4321, 16);
      let sameSeedSame = true;
      let diffSeedDiff = false;
      for (let i = 0; i < a1.length; i++) {
        if (a1[i] !== a2[i]) {
          sameSeedSame = false;
        }
        if (Math.abs(a1[i] - b[i]) > 1e-9) {
          diffSeedDiff = true;
        }
      }
      expect(sameSeedSame).assertTrue();
      expect(diffSeedDiff).assertTrue();
    });

    it('spectrumChangesSmoothly', 0, () => {
      // 相邻 16ms（约一帧）柱高变化有限，画面不会跳变
      const a = synthSpectrum(7, 10000, 24);
      const b = synthSpectrum(7, 10016, 24);
      for (let i = 0; i < a.length; i++) {
        expect(Math.abs(a[i] - b[i]) < 0.1).assertTrue();
      }
    });

    it('beatEnvelopeRangeAndPeriod', 0, () => {
      const period = 60000 / 120;
      for (let t = 0; t < period * 3; t += 7) {
        const e = beatEnvelope(t, 120, 0);
        expect(e >= 0.25 - 1e-9).assertTrue();
        expect(e <= 1 + 1e-9).assertTrue();
      }
      // 同相位隔一拍包络应一致
      expect(Math.abs(beatEnvelope(0, 120, 0) - beatEnvelope(period, 120, 0)) < 1e-9).assertTrue();
      // bpm 收敛到 [40,220]
      expect(bpmFromSeed(1) >= 90 && bpmFromSeed(1) <= 150).assertTrue();
    });


    it('splitHighlightSegments', 0, () => {
      // 空关键词：整段未命中
      const none = splitHighlight('晨光旋律', '');
      expect(none.length).assertEqual(1);
      expect(none[0].text).assertEqual('晨光旋律');
      expect(none[0].hit).assertFalse();
      // 单次命中：前后未命中段保留
      const one = splitHighlight('晨光旋律', '光旋');
      expect(one.length).assertEqual(3);
      expect(one[0].text + one[1].text + one[2].text).assertEqual('晨光旋律');
      expect(one[1].hit).assertTrue();
      expect(one[0].hit || one[2].hit).assertFalse();
      // 多次命中 + 大小写不敏感
      const many = splitHighlight('abcAbcABC', 'ab');
      let hits = 0;
      let joined = '';
      for (const seg of many as TextSegment[]) {
        joined += seg.text;
        if (seg.hit) {
          hits++;
        }
      }
      expect(joined).assertEqual('abcAbcABC');
      expect(hits).assertEqual(3);
      // 无命中：单段
      const miss = splitHighlight('晨光旋律', '雨后');
      expect(miss.length).assertEqual(1);
      expect(miss[0].hit).assertFalse();
    });

    it('hslToRgbKnownValues', 0, () => {
      expectRgb(hslToRgb(0, 1, 0.5), 255, 0, 0);
      expectRgb(hslToRgb(120, 1, 0.5), 0, 255, 0);
      expectRgb(hslToRgb(240, 1, 0.5), 0, 0, 255);
      expectRgb(hslToRgb(210, 0.5, 0), 0, 0, 0);
      expectRgb(hslToRgb(-120, 1, 0.5), 0, 0, 255);
    });
  });

  describe('FftTest', () => {
    it('isPowerOfTwo', 0, () => {
      expect(isPowerOfTwo(1)).assertTrue();
      expect(isPowerOfTwo(1024)).assertTrue();
      expect(isPowerOfTwo(0)).assertFalse();
      expect(isPowerOfTwo(1000)).assertFalse();
    });

    it('sinePeakAtExpectedBin', 0, () => {
      // 16kHz 采样、1024 点窗：440Hz 正弦主峰应落在 bin 28（440/15.625）
      const n = 1024;
      const sig = new Float32Array(n);
      for (let i = 0; i < n; i++) {
        sig[i] = 0.5 * Math.sin(2 * Math.PI * 440 * i / 16000);
      }
      const mag = fftMagnitudes(sig);
      expect(mag.length).assertEqual(n / 2);
      let peak = 0;
      for (let i = 1; i < mag.length; i++) {
        if (mag[i] > mag[peak]) {
          peak = i;
        }
      }
      expect(peak).assertEqual(28);
      // 汉宁窗前主峰幅度 0.5（0.5 幅度正弦归一化后 ≈ 0.5），容差 0.1
      expect(mag[peak] > 0.4).assertTrue();
      expect(mag[peak] < 0.6).assertTrue();
    });

    it('dcInputOnlyBin0', 0, () => {
      const sig = new Float32Array(256);
      sig.fill(0.25);
      const mag = fftMagnitudes(sig);
      // 直流信号能量全在 bin 0，其余 bin 应近零
      expect(mag[0] > 0.24).assertTrue();
      for (let i = 1; i < mag.length; i++) {
        expect(mag[i] < 1e-6).assertTrue();
      }
    });
  });

  describe('OnlineCacheTest', () => {
    it('isCacheFreshShouldRespectTtlAndClock', 0, () => {
      const ttl = 10 * 60 * 1000;
      expect(isCacheFresh(1000, 1000, ttl)).assertTrue();
      expect(isCacheFresh(1000, 1000 + ttl - 1, ttl)).assertTrue();
      expect(isCacheFresh(1000, 1000 + ttl, ttl)).assertFalse();
      // 时钟回拨（now 早于采样时刻）视为不新鲜
      expect(isCacheFresh(2000, 1000, ttl)).assertFalse();
      expect(isCacheFresh(0, 5000, ttl)).assertFalse();
    });

    it('serializeParseShouldRoundTrip', 0, () => {
      const base = DEFAULT_ONLINE_BASE_URL;
      const entry = mkEntry(base, 1700000000000);
      const text = serializeOnlineCache(entry);
      const restored = parseOnlineCache(text, base);
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.baseUrl).assertEqual(base);
        expect(restored.savedAt).assertEqual(entry.savedAt);
        expect(restored.songs.length).assertEqual(1);
        expect(restored.songs[0].id).assertEqual('online:1');
        expect(restored.songs[0].title).assertEqual('雨后琶音');
      }
    });

    it('parseShouldRejectCorruptMismatchedAndEmpty', 0, () => {
      const base = DEFAULT_ONLINE_BASE_URL;
      expect(parseOnlineCache('', base)).assertNull();
      expect(parseOnlineCache('not-json', base)).assertNull();
      // baseUrl 不一致（换服务端）：旧缓存失效
      const other = serializeOnlineCache(mkEntry('https://example.com/api/music', 1700000000000));
      expect(parseOnlineCache(other, base)).assertNull();
      // 空列表不值得缓存
      const emptySongs: SongRecord[] = [];
      const emptyEntry: OnlineCacheEntry = { baseUrl: base, savedAt: 1700000000000, songs: emptySongs };
      expect(parseOnlineCache(serializeOnlineCache(emptyEntry), base)).assertNull();
      // 结构损坏：歌目缺 fileName
      const brokenSong: SongRecord = { id: 'online:1', title: 'x', artist: '', album: '', duration: 0, fileName: '', coverPath: '' };
      const brokenEntry: OnlineCacheEntry = { baseUrl: base, savedAt: 1700000000000, songs: [brokenSong] };
      expect(parseOnlineCache(serializeOnlineCache(brokenEntry), base)).assertNull();
    });
  });

  describe('GesturePathTest', () => {
    it('earlyNeedsTwoPoints', 0, () => {
      expect(earlyClassifyStroke([[10, 10]])).assertNull();
    });
    it('earlyRightApexNextTab', 0, () => {
      // 向右走出 50 后折回 30:右顶点 `>` = 下一个签
      const act = earlyClassifyStroke([[0, 0], [50, 2], [20, 4]]);
      expect(act !== null).assertTrue();
      expect(act!.kind === 'tab').assertTrue();
      expect(act!.dir).assertEqual(1);
    });
    it('earlyLeftApexPrevTab', 0, () => {
      const act = earlyClassifyStroke([[0, 0], [-50, 2], [-20, 4]]);
      expect(act !== null).assertTrue();
      expect(act!.kind === 'tab').assertTrue();
      expect(act!.dir).assertEqual(-1);
    });
    it('earlyStraightSlideDoesNotFire', 0, () => {
      // 平直横滑走出 50 但无折回:折返前半段,早认不得开枪(否则误杀切歌)
      expect(earlyClassifyStroke([[0, 0], [30, 0], [50, 0], [80, 0]])).assertNull();
    });
    it('earlyVerticalDriftIgnored', 0, () => {
      // 纵向漂移 >=50vp 的大对角不早认(走抬手兜底通道)
      const act = earlyClassifyStroke([[0, 0], [60, 30], [60, 70]]);
      expect(act).assertNull();
    });
    it('earlyApexBoundariesInclusive', 0, () => {
      // 走出恰好 45 + 折回恰好 25:阈值含边界
      const act = earlyClassifyStroke([[0, 0], [45, 0], [20, 0]]);
      expect(act !== null).assertTrue();
      expect(act!.dir).assertEqual(1);
    });
    it('endFoldedApexIsTab', 0, () => {
      // 折返:跨度 80、折回 40、纵向推进 20
      const act = classifyStrokeEnd([[0, 0], [80, 5], [40, 20]]);
      expect(act !== null).assertTrue();
      expect(act!.kind === 'tab').assertTrue();
      expect(act!.dir).assertEqual(1);
    });
    it('endFlatFoldFallsThroughToTrack', 0, () => {
      // 压平的 </>(跨度达标、折回达标、纵向 <15):现有行为按平直横滑
      // 分类为切歌——钉住该现状,阈值调整时此处会显式失败提醒
      const act = classifyStrokeEnd([[0, 0], [80, 2], [40, 4]]);
      expect(act !== null).assertTrue();
      expect(act!.kind === 'track').assertTrue();
    });
    it('endStraightSwipeLeftIsNextTrack', 0, () => {
      const act = classifyStrokeEnd([[0, 0], [-60, 1], [-120, 2]]);
      expect(act !== null).assertTrue();
      expect(act!.kind === 'track').assertTrue();
      expect(act!.dir).assertEqual(-1);
    });
    it('endTrackTravelBoundary', 0, () => {
      // 横向恰好 40vp:含边界;纵向恰好 40vp:严格不触发
      expect(classifyStrokeEnd([[0, 0], [-40, 0]]) !== null).assertTrue();
      expect(classifyStrokeEnd([[0, 0], [0, -40]])).assertNull();
    });
    it('endSmallMoveIgnored', 0, () => {
      expect(classifyStrokeEnd([[0, 0], [20, 3], [30, 6]])).assertNull();
    });
  });

  describe('FirstGlyphTest', () => {
    it('emptyReturnsEmpty', 0, () => {
      expect(firstGlyph('')).assertEqual('');
    });
    it('bmpCharReturnedAsIs', 0, () => {
      expect(firstGlyph('晨光')).assertEqual('晨');
    });
    it('astralCharNotSplit', 0, () => {
      // 增补平面字符按 code point 取,不被代理对劈半(substring(0,1) 会碎)
      expect(firstGlyph('🎵音乐')).assertEqual('🎵');
    });
    it('singleCharPassthrough', 0, () => {
      expect(firstGlyph('A')).assertEqual('A');
    });
  });

  describe('TimeUtilsEdgeTest', () => {
    it('formatTimeNaNFallsBackToZero', 0, () => {
      expect(formatTime(NaN)).assertEqual('00:00');
    });
    it('formatTimeOverHundredMinutesNoPadding', 0, () => {
      expect(formatTime(6000000)).assertEqual('100:00');
    });
    it('formatTotalDurationNonFiniteIsZero', 0, () => {
      expect(formatTotalDuration(NaN)).assertEqual('0 分钟');
      expect(formatTotalDuration(Infinity)).assertEqual('0 分钟');
    });
  });

  describe('OnlineHealthTest', () => {
    it('healthUrlTrimsTrailingSlash', 0, () => {
      expect(healthUrl('https://h.example/api/v1/')).assertEqual('https://h.example/api/v1/health');
    });
    it('parseRejectsEmptyBrokenOrMissingVersion', 0, () => {
      expect(parseOnlineHealth('')).assertNull();
      expect(parseOnlineHealth('   ')).assertNull();
      expect(parseOnlineHealth('not-json')).assertNull();
      expect(parseOnlineHealth('{}')).assertNull();
      expect(parseOnlineHealth('{"version":""}')).assertNull();
      expect(parseOnlineHealth('{"version":123}')).assertNull();
    });
    it('parseAcceptsVersionString', 0, () => {
      const info = parseOnlineHealth('{"version":"1.2.0"}');
      expect(info !== null).assertTrue();
      expect(info!.version).assertEqual('1.2.0');
    });
  });

  describe('LibraryFilterExtraTest', () => {
    it('sortTitleAsc', 0, () => {
      const songs = [mk('1', 'banana', 'a', 1000), mk('2', 'apple', 'a', 1000), mk('3', 'cherry', 'a', 1000)];
      const out = filterAndSort(songs, {
        query: '', tab: LibraryTab.ALL, sort: SortMode.TITLE,
        favoriteIds: [], recentIds: [], onlineSongs: []
      });
      expect(out[0].title).assertEqual('apple');
      expect(out[2].title).assertEqual('cherry');
    });
    it('sortLabelCoversAllModes', 0, () => {
      expect(sortLabel(SortMode.DEFAULT)).assertEqual('默认排序');
      expect(sortLabel(SortMode.TITLE)).assertEqual('按歌名');
      expect(sortLabel(SortMode.ARTIST)).assertEqual('按歌手');
      expect(sortLabel(SortMode.DURATION)).assertEqual('按时长');
    });
  });

  // 曲库文件名元数据解析（MusicLibrary.fillFromFileName 的纯函数形态）：
  // 无 ID3 标签时的唯一元数据来源,约定跨客户端与服务端(music_server 的
  // parseSongName/stripSerialPrefix 同源),零测试覆盖多年。
  describe('FileNameMetaTest', () => {
    it('parsesArtistAndTitle', 0, () => {
      const m = parseFileNameMeta('周杰伦 - 晴天.mp3');
      expect(m.artist).assertEqual('周杰伦');
      expect(m.title).assertEqual('晴天');
    });
    it('stripsDemoSerialPrefix', 0, () => {
      // rawfile 演示曲目命名「demoXX_歌手 - 歌名.ext」
      const m = parseFileNameMeta('demo03_拾光者 - 温柔节拍.wav');
      expect(m.artist).assertEqual('拾光者');
      expect(m.title).assertEqual('温柔节拍');
    });
    it('noSeparatorFallsBackTitleOnly', 0, () => {
      const m = parseFileNameMeta('未命名曲目.flac');
      expect(m.title).assertEqual('未命名曲目');
      expect(m.artist).assertEqual(LOCAL_ARTIST_FALLBACK);
      expect(LOCAL_ARTIST_FALLBACK).assertEqual('本地音乐');
    });
    it('trimsWhitespaceAroundParts', 0, () => {
      const m = parseFileNameMeta('  歌手  -   歌名  .mp3');
      expect(m.artist).assertEqual('歌手');
      expect(m.title).assertEqual('歌名');
    });
    it('splitsOnFirstSeparatorOnly', 0, () => {
      // 歌名本身含「 - 」时只按第一个分割,后续留给歌名
      const m = parseFileNameMeta('A - B - C.mp3');
      expect(m.artist).assertEqual('A');
      expect(m.title).assertEqual('B - C');
    });
    it('keepsDotsInTitleWithoutExtConfusion', 0, () => {
      // 文件名带多点:只剥最后一个扩展名,其余留给歌名
      const m = parseFileNameMeta('歌手 - v1.2.3.mp3');
      expect(m.artist).assertEqual('歌手');
      expect(m.title).assertEqual('v1.2.3');
    });
    it('handlesMissingExtension', 0, () => {
      // 无扩展名:整体参与解析,不去名
      const m = parseFileNameMeta('歌手 - 无扩展名');
      expect(m.artist).assertEqual('歌手');
      expect(m.title).assertEqual('无扩展名');
    });
    it('emptyAndEdgeInputs', 0, () => {
      expect(parseFileNameMeta('').title).assertEqual('');
      expect(parseFileNameMeta('').artist).assertEqual(LOCAL_ARTIST_FALLBACK);
      // 前导点(隐藏文件形态)不去名
      const m = parseFileNameMeta('.mp3');
      expect(m.title).assertEqual('.mp3');
    });
    it('doesNotStripNonSerialPrefix', 0, () => {
      // 前缀不含数字不剥离(与 music_server 的 stripSerialPrefix 同口径)
      const m = parseFileNameMeta('Love_Story.mp3');
      expect(m.title).assertEqual('Love_Story');
      expect(m.artist).assertEqual(LOCAL_ARTIST_FALLBACK);
    });
  });

  // 缓存文件名派生（OnlineCache.filePath 的纯函数形态）：决定「缓存文件 ↔
  // 索引 key」映射,错一度意味着缓存 miss 重下(流量)或孤儿被对账清掉(已下
  // 音频丢失),且含 hash 兜底的碰撞规避逻辑。
  describe('CacheFileNameTest', () => {
    it('cleanIdKeepsStableName', 0, () => {
      // 干净 id(仅 [a-zA-Z0-9_-])不加 hash,已缓存文件零迁移
      expect(cacheFileName('abc123')).assertEqual('abc123.audio');
      expect(cacheFileName('a-b_c')).assertEqual('a-b_c.audio');
    });
    it('escapedIdAppendsHashSuffix', 0, () => {
      // online: 前缀含冒号 → 转义为 _ 并追加 hash 短串
      const name = cacheFileName('online:ne_12345');
      expect(name.startsWith('online_ne_12345.')).assertTrue();
      expect(name.endsWith('.audio')).assertTrue();
      // hash 段存在且非空
      const mid = name.substring('online_ne_12345.'.length, name.length - CACHE_FILE_SUFFIX.length);
      expect(mid.length > 0).assertTrue();
    });
    it('collisionProneIdsGetDistinctNames', 0, () => {
      // 转义会折叠(不同 id 折出同名),hash 兜底必须让它们不互相覆盖——
      // 这是该函数存在的核心理由
      const a = cacheFileName('online:a/b');
      const b = cacheFileName('online:a_b');
      expect(a !== b).assertTrue();
      const c = cacheFileName('online:a:b');
      const d = cacheFileName('online:a-b');
      expect(c !== d).assertTrue();
    });
    it('sameIdIsDeterministic', 0, () => {
      // 同 id 必须稳定派生:缓存命中依赖跨进程/重启的一致性
      const first = cacheFileName('online:ne_999');
      for (let i = 0; i < 5; i++) {
        expect(cacheFileName('online:ne_999')).assertEqual(first);
      }
    });
    it('hashIsNonNegative', 0, () => {
      // hash 与 0x7fffffff 相与保证非负:toString(36) 不能产出负号段
      for (const id of ['online:x', 'online:y', 'online:z', 'a:b:c:d']) {
        const name = cacheFileName(id);
        expect(name.indexOf('-') < 0).assertTrue();
      }
    });
    it('emptyIdHandled', 0, () => {
      // 空串:转义后仍等于自身(无非法字符),走干净分支
      expect(cacheFileName('')).assertEqual('.audio');
    });
    it('constantsAreStable', 0, () => {
      // 常量被索引读写/对账共用,值漂移会让旧缓存全部对不上
      expect(CACHE_FILE_SUFFIX).assertEqual('.audio');
      expect(CACHE_INDEX_FILE).assertEqual('index.json');
    });
  });

  describe('OnlineApiExtraTest', () => {
    const base = 'https://music.example/api/v1';
    it('parseOnlineSongsSkipsBadEntries', 0, () => {
      // 手工拼畸形 JSON(混 null 条目/缺 id/类型错误的字段)——服务端异常
      // 响应的真实形态,ArkTS 对象字面量无法表达这种混合结构
      const body = '{"songs":[null,{"title":"no id"},{"id":"","title":"empty id"},' +
        '{"id":"vip1","title":42,"artist":123,"album":null,"durationMs":0},' +
        '{"id":"ok1","title":"好歌","artist":"人","album":"专辑","durationMs":21000,"vip":true}]}';
      const songs = parseOnlineSongs(base, body);
      expect(songs.length).assertEqual(2);
      // title 非 string 回落为原始 id;artist 非 string 回落空串
      expect(songs[0].title).assertEqual('vip1');
      expect(songs[0].artist).assertEqual('');
      expect(songs[0].duration).assertEqual(0);
      // 合法条目完整映射
      expect(songs[1].title).assertEqual('好歌');
      expect(songs[1].artist).assertEqual('人');
      expect(songs[1].duration).assertEqual(21000);
      expect(songs[1].vip).assertTrue();
    });
    it('parseOnlineCacheRejectsWrongVersionOrMeta', 0, () => {
      const songs: SongRecord[] = [mkOnline('1', 'x')];
      const entry: OnlineCacheEntry = { baseUrl: base, savedAt: 1700000000000, songs: songs };
      const patch = (patchObj: Record<string, Object>): string => {
        const raw = JSON.parse(serializeOnlineCache(entry)) as Record<string, Object>;
        const keys = Object.keys(patchObj);
        for (const k of keys) {
          raw[k] = patchObj[k];
        }
        return JSON.stringify(raw);
      };
      // 版本号不符(旧版本文件)
      expect(parseOnlineCache(patch({ 'version': 999 }), base)).assertNull();
      // savedAt 非 number
      expect(parseOnlineCache(patch({ 'savedAt': 'yesterday' }), base)).assertNull();
      // songs 非数组
      expect(parseOnlineCache(patch({ 'songs': 'all' }), base)).assertNull();
    });
  });
}
