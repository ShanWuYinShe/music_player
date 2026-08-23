import { describe, it, expect } from '@ohos/hypium';
import { PlayMode, nextPlayMode, playModeLabel } from '../main/ets/model/PlayMode';
import { formatTime, formatTotalDuration } from '../main/ets/common/TimeUtils';
import { SongRecord } from '../main/ets/model/Song';
import { LibraryTab, SortMode, filterAndSort } from '../main/ets/common/LibraryFilter';
import { ONLINE_ID_PREFIX, normalizeBaseUrl, effectiveBaseUrl, DEFAULT_ONLINE_BASE_URL, songsUrl, parseOnlineSongs, OnlineSongItem, OnlineSongsResponse } from '../main/ets/source/OnlineApi';

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
  });
}
