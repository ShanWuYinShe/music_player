/**
 * MicSpectrum：麦克风律动——采集环境声做真频谱，驱动可视化舞台的
 * beat/bass/treble（替代 VisualizerCore 合成，外放场景可视化随真实
 * 音乐跳动）。
 *
 * 架构：AVAudioCapturer（16kHz 单声道 S16LE）→ readData 事件（约 31Hz）
 * → 1024 点滑窗 + 汉宁窗 → FFT → bass/treble 频段聚合 + beat 突增检测
 * → 就地更新 levels，供 VisualizerView 帧循环拉取（不回调，避免时序）。
 *
 * 限制（已知且接受）：耳机/静音播放时麦克风收不到外放声，可视化自动
 * 失效回退合成（levels 长时间无能量时 valid=false）；采集器失败（无
 * 麦克风/权限被拒）start() 返回 false，由设置开关回退并提示。
 */

import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fftMagnitudes, isPowerOfTwo } from './Fft';

const TAG = 'MicSpectrum';
const DOMAIN = 0x0002;

const FFT_SIZE = 1024;
// 16kHz / 1024 点 → bin 带宽 15.625Hz
const BASS_BIN_LO = 2;      // ~31Hz
const BASS_BIN_HI = 16;     // ~250Hz
const TREBLE_BIN_LO = 128;  // ~2kHz
const TREBLE_BIN_HI = 384;  // ~6kHz（更高频段环境噪声占比大，取保守上界）
// 标定常数（S16 归一化后的幅度谱经验缩放），真机校准后如有偏差在此调
const BASS_GAIN = 6;
const TREBLE_GAIN = 14;
const BEAT_RATIO = 1.4;     // bass 瞬时超过慢均值该比例视为一拍
const BEAT_FLOOR = 0.02;    // 低能量段不触发拍（环境底噪）
const BEAT_DECAY = 0.90;    // 每个 readData 事件的拍包络衰减（~31Hz 下约 0.07s 半衰）
const SMOOTH_ATTACK = 0.55; // 频段电平 EMA：快攻
const SMOOTH_RELEASE = 0.82;// 慢放（视觉不闪烁）
/** valid 判定：最近 N 个窗口的最大 bass 低于此值视为无声（自动回退合成） */
const SILENCE_FLOOR = 0.004;
const SILENCE_WINDOW = 96;  // ~3s 无声判定

export interface SpectrumLevels {
  beat: number;
  bass: number;
  treble: number;
}

export class MicSpectrum {
  private capturer: audio.AudioCapturer | null = null;
  private win: Float32Array = new Float32Array(FFT_SIZE);
  private hann: Float32Array = new Float32Array(0);
  private bassSlow = 0;
  private beatEnv = 0;
  private bassSmooth = 0;
  private trebleSmooth = 0;
  private recentMax = 0;
  private quietRuns = 0;
  /** 最新频段电平（帧循环拉取）；valid=false 表示无有效环境声 */
  readonly levels: SpectrumLevels = { beat: 0, bass: 0, treble: 0 };
  valid = false;
  active = false;

  /** 在途 start 承诺：并发调用复用同一份，stop 也等它落定后再收——
   * 否则快速连点会创建两个采集器（前者被覆盖泄漏、麦克风持续采集） */
  private startPromise: Promise<boolean> | null = null;

  /** 创建并启动采集；失败（无麦克风/被系统拒绝）返回 false，调用方回退 */
  async start(): Promise<boolean> {
    if (this.active) {
      return true;
    }
    if (this.startPromise !== null) {
      return this.startPromise;
    }
    this.startPromise = this.doStart();
    const result = await this.startPromise.finally(() => {
      this.startPromise = null;
    });
    return result;
  }

  private async doStart(): Promise<boolean> {
    let capturer: audio.AudioCapturer | null = null;
    try {
      const opts: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_MIC,
          capturerFlags: 0
        }
      };
      capturer = await audio.createAudioCapturer(opts);
      capturer.on('readData', (buf: ArrayBuffer) => this.onRead(buf));
      await capturer.start();
      this.capturer = capturer;
      this.hann = new Float32Array(FFT_SIZE);
      for (let i = 0; i < FFT_SIZE; i++) {
        this.hann[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / FFT_SIZE);
      }
      this.active = true;
      this.valid = false;
      hilog.info(DOMAIN, TAG, 'mic capturer started');
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'mic capturer start failed: %{public}s', JSON.stringify(err));
      // 创建成功但 start 失败的实例必须释放（否则泄漏采集器与 readData 监听）
      if (capturer !== null) {
        try {
          await capturer.release();
        } catch (releaseErr) {
        }
      }
      this.capturer = null;
      return false;
    }
  }

  async stop(): Promise<void> {
    if (this.startPromise !== null) {
      await this.startPromise.catch(() => {
      });
    }
    const cap = this.capturer;
    this.capturer = null;
    this.active = false;
    this.valid = false;
    this.levels.beat = 0;
    this.levels.bass = 0;
    this.levels.treble = 0;
    if (cap !== null) {
      try {
        await cap.stop();
        await cap.release();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'mic capturer stop failed: %{public}s', JSON.stringify(err));
      }
    }
  }

  /** readData 事件：样本推进滑窗 → 窗控 FFT → 频段聚合 + 拍检测 */
  private onRead(buf: ArrayBuffer): void {
    if (!this.active || !isPowerOfTwo(FFT_SIZE)) {
      return;
    }
    const s16 = new Int16Array(buf);
    const k = Math.min(s16.length, FFT_SIZE);
    if (k < FFT_SIZE) {
      this.win.copyWithin(0, FFT_SIZE - k);
      for (let i = 0; i < k; i++) {
        this.win[FFT_SIZE - k + i] = s16[i] / 32768;
      }
    } else {
      for (let i = 0; i < FFT_SIZE; i++) {
        this.win[i] = s16[s16.length - FFT_SIZE + i] / 32768;
      }
    }
    // 汉宁窗 + FFT
    const windowed = new Float32Array(FFT_SIZE);
    for (let i = 0; i < FFT_SIZE; i++) {
      windowed[i] = this.win[i] * this.hann[i];
    }
    const mag = fftMagnitudes(windowed);
    // 频段聚合（算术均值；汉宁窗幅度衰减已在 GAIN 标定吸收）
    let bassSum = 0;
    for (let i = BASS_BIN_LO; i <= BASS_BIN_HI; i++) {
      bassSum += mag[i];
    }
    let trebleSum = 0;
    for (let i = TREBLE_BIN_LO; i <= TREBLE_BIN_HI; i++) {
      trebleSum += mag[i];
    }
    const bassRaw = Math.min(1, bassSum / (BASS_BIN_HI - BASS_BIN_LO + 1) * BASS_GAIN);
    const trebleRaw = Math.min(1, trebleSum / (TREBLE_BIN_HI - TREBLE_BIN_LO + 1) * TREBLE_GAIN);
    // EMA：快攻慢放，视觉不闪烁
    const k1 = bassRaw > this.bassSmooth ? SMOOTH_ATTACK : SMOOTH_RELEASE;
    this.bassSmooth += (bassRaw - this.bassSmooth) * k1;
    const k2 = trebleRaw > this.trebleSmooth ? SMOOTH_ATTACK : SMOOTH_RELEASE;
    this.trebleSmooth += (trebleRaw - this.trebleSmooth) * k2;
    // 拍检测：bass 瞬时显著超过慢均值
    this.bassSlow = this.bassSlow * 0.95 + bassRaw * 0.05;
    if (bassRaw > this.bassSlow * BEAT_RATIO && bassRaw > BEAT_FLOOR) {
      this.beatEnv = 1;
    } else {
      this.beatEnv *= BEAT_DECAY;
    }
    // 无声自动回退：近 3s 无有效能量 → valid=false（可视化用合成）
    this.recentMax = Math.max(this.recentMax * 0.99, bassRaw);
    if (this.recentMax < SILENCE_FLOOR) {
      this.quietRuns++;
    } else {
      this.quietRuns = 0;
    }
    this.valid = this.quietRuns < SILENCE_WINDOW;
    this.levels.beat = this.beatEnv;
    this.levels.bass = this.bassSmooth;
    this.levels.treble = this.trebleSmooth;
  }
}
