import { describe, it, expect } from '@ohos/hypium';
import { PlayMode, nextPlayMode, playModeLabel } from '../main/ets/model/PlayMode';
import { formatTime, formatTotalDuration } from '../main/ets/common/TimeUtils';
import { SongRecord } from '../main/ets/model/Song';
import { LibraryTab, SortMode, filterAndSort, splitHighlight, TextSegment } from '../main/ets/common/LibraryFilter';
import {
  ONLINE_ID_PREFIX, normalizeBaseUrl, effectiveBaseUrl, DEFAULT_ONLINE_BASE_URL,
  songsUrl, providersUrl, parseOnlineSongs, parseOnlineProviders,
  OnlineSongItem, OnlineSongsResponse
} from '../main/ets/source/OnlineApi';
import {
  PRESET_COUNT, VIZ_PRESET_NAMES, seedFromId, synthSpectrum,
  beatEnvelope, bpmFromSeed, hslToRgb, normalizeTilt,
  normalizeSpin, wrapAngleDelta, accelKickLevel
} from '../main/ets/common/VisualizerCore';
import { parseTlenMs } from '../main/ets/library/Id3ParserCore';
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
}
