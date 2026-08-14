import { describe, it, expect } from '@ohos/hypium';
import { PlayMode, nextPlayMode, playModeLabel } from '../main/ets/model/PlayMode';
import { formatTime } from '../main/ets/common/TimeUtils';

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
  });
}
