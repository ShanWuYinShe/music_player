/**
 * VisualizerView：MilkDrop 风格音乐可视化（@ComponentV2）。
 *
 * 平台无频谱 API，频段能量由 VisualizerCore 合成（种子 = 曲目 id）。
 * XComponent(SURFACE)+GLES3 shader 管线，打包无限分形、热锅水珠、
 * 全屏极光、霓虹频谱四个场景；运算量只与像素数相关，内部按场景比例
 * 降采样（fractal/spectrum 1/2，pan 0.45、aurora 0.33——后两者逐像素
 * 成本高且形态柔软，更低比例上屏放大视觉近无损；pan 另有状态预通道，
 * 见 cpp/shaders/pan.frag）渲染后线性上屏，反馈纹理仅供拖尾场景采样。
 * 帧驱动 displaySync 限 30fps（场景级帧间隔见 VIZ_FRAME_INTERVAL_MS——
 * 极光 25fps 仍无感），暂停后跑约 0.9s 收敛即停。
 * active=false（播放页封面模式）停帧不渲染——封面与可视化互斥，避免
 * 全速渲染被遮挡的画面。（迷你条频谱已移除，2026-09 用户决策）
 */

import displaySync from '@ohos.graphics.displaySync';
import sensor from '@ohos.sensor';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  seedFromId, synthSpectrum, beatEnvelope, bpmFromSeed, hash01, hslToRgb, normalizeTilt,
  normalizeSpin, wrapAngleDelta, accelKickLevel,
  PRESET_COUNT, VIZ_FRAME_INTERVAL_MS
} from '../common/VisualizerCore';
import { appStore } from '../viewmodel/AppStore';
import entry from 'libentry.so';

/** XComponent onLoad 回调的运行时 context 形态（声明层面为 object，此处收窄） */
interface XComponentNativeHandle {
  getNativeHandle(): number;
}

interface XComponentVizContext {
  __NATIVE_XCOMPONENT_OBJ__: XComponentNativeHandle;
}

/** 暂停后收敛动画时长（ms），之后停帧保留静帧 */
const FADE_MS = 900;
/** 绘帧最小间隔兜底：须小于 displaySync 回调间隔 + 余量才能保证每次
 * 回调都落帧。高刷真机上 displaySync 超预期回调（30fps≈33.3ms），阈值取
 * 25ms 容差；此前 36ms 阈值把 33.3ms 回调成片跳过（实际 15fps 脉冲闪，已
 * 踩坑，与 2D 管线内容耗时 46ms 时"内容主导"的失败模式不同）。
 * 常规按场景取 VIZ_FRAME_INTERVAL_MS（aurora 40ms=25fps——慢场景
 * 无感，真机 GPU 超载时同步 renderFrame 会阻塞 UI 线程，降帧率治本）。 */
const FRAME_MIN_INTERVAL = 25;

@ComponentV2
export struct VisualizerView {
  /** 播放态 @Param 镜像（父页面经状态订阅维护后下发；跨单例直读
   * player @Trace 在真机上不可靠，启停/切歌漏触发即后台空烧 GPU） */
  @Param isPlaying: boolean = false;
  /** 当前曲 id @Param 镜像（种子/时钟重置依据，同上） */
  @Param songId: string = '';
  /** 当前风格号（父页面持有，经顶栏魔法棒菜单切换；@Param 回流驱动渐变） */
  @Param presetIndex: number = 0;
  /** 舞台是否激活：false 时停帧不渲染（播放页封面模式——封面与可视化互斥，
   * 不再全速渲染被遮挡的画面）；XComponent/Canvas 保持挂载，恢复即续播 */
  @Param active: boolean = true;
  /** 麦克风律动（设置页开关镜像）：true 且舞台激活时用麦克风真频谱驱动
   * beat/bass/treble（外放场景），无效/关闭时回退合成 */
  @Param micLive: boolean = false;
  /** 风格过渡进度 0→1（切换后 1.5s 内新场景渐入，旧画面靠反馈余晖消散） */
  private presetTrans: number = 1;

  private ds: displaySync.DisplaySync | null = null;
  /** frame 具名回调：匿名闭包无法 off('frame') 注销，重进会堆积回调 */
  private frameCb: () => void = () => this.frame();

  private running = false;
  private disposed = false;
  private ready = false;
  /** 场景 program 是否已画出首帧（后台编译完成标志）：false 时叠编译中
   * 占位层，true 后淡出——避免切到可视化时的空屏 */
  @Local vizReady: boolean = false;
  /** 占位层可见性（跟随 vizReady 淡出后彻底移除） */
  @Local placeholderOn: boolean = true;
  /** 占位柔光呼吸值（0.35~0.6 循环，displaySync 已有帧驱动，复用它） */
  @Local placeholderBreath: number = 0.5;

  private lastSongId = '';
  private seed = 0;
  /** 设备倾斜（ORIENTATION 姿态角经 normalizeTilt+低通，[-1,1]）：每帧作
   * shader uTilt——全场景相机视差；传感器不可用（模拟器/权限异常）保持
   * 0，效果退化为现状 */
  private tiltX = 0;
  private tiltY = 0;
  /** 面内旋转（ORIENTATION alpha 相对舞台进入时基准的差分，经
   * normalizeSpin+低通，[-1,1]）：每帧作 shader uSpin——全场景滚转，
   * 只进几何。磁力计漂移时靠死区抑制，无传感器时保持 0 */
  private spin = 0;
  private spinBase: number | null = null;
  /** 抛甩激励包络（LINEAR_ACCELEROMETER 瞬时量 attack、逐帧指数 decay，
   * 0..1）：每帧作 shader uKick——只进已有音频量的亮度/尺寸通道。
   * 权限被拒/无传感器时保持 0，倾斜旋转照常 */
  private kick = 0;
  private orientationOn = false;
  private accelOn = false;
  private tiltLogged = false;
  /** 抛甩包络衰减时间常数（ms）：挥动后约 0.6s 回落，甩动有"余震" */
  private static readonly KICK_DECAY_MS = 600;
  /** 当前风格号（仅点击可视化区域切换，无自动轮换） */
  private presetLock: number = 0;
  private beatPhase = 0;
  /** 有效播放时钟：暂停期间不走，保证画面冻结在暂停时刻 */
  private playClock = 0;
  private lastNow = 0;
  private fadeDeadline = 0;

  aboutToAppear(): void {
    this.ds = displaySync.create();
    const range: ExpectedFrameRateRange = { min: 0, max: 30, expected: 30 };
    this.ds.setExpectedFrameRateRange(range);
    this.ds.on('frame', this.frameCb);
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.stopLoop();
    if (this.ds !== null) {
      this.ds.off('frame', this.frameCb);
      this.ds = null;
    }
    this.syncSensor();
    // 麦克风律动开着退出播放页必须停采集：disposed=true 已让 syncMic 走
    // stop 分支——漏掉这一步 AVAudioCapturer 会持续采到用户手动关闭为止
    // （指示灯不灭、耗电、隐私）
    this.syncMic();
  }

  @Monitor('isPlaying', 'songId')
  onPlayerStateChange(): void {
    this.syncState();
  }

  /** 舞台激活态变化：失活立即停帧（GPU 归零），激活时按播放态恢复 */
  @Monitor('active')
  onActiveChange(): void {
    this.syncState();
  }

  /** 麦克风律动开关变化：跟随舞台激活态启停采集器 */
  @Monitor('micLive')
  onMicLiveChange(): void {
    this.syncMic();
  }

  /** 采集器启停：只在舞台可见且开关打开时耗麦克风（省电） */
  private syncMic(): void {
    const mic = appStore.mic;
    if (this.micLive && this.active && !this.disposed) {
      mic.start().catch((err: Object) => {
        hilog.warn(0x0004, 'VizView', 'mic start failed: %{public}s', JSON.stringify(err));
      });
    } else if (mic.active) {
      mic.stop().catch((err: Object) => {
        hilog.warn(0x0004, 'VizView', 'mic stop failed: %{public}s', JSON.stringify(err));
      });
    }
  }

  /** 传感器订阅启停（仅 full 变体激活时持有，省电）：
   * ORIENTATION（免权限）：beta/gamma→uTilt 视差，alpha 差分→uSpin 滚转，
   *   'ui' 档 60ms 上报对慢速视差足够；
   * LINEAR_ACCELEROMETER（需 ohos.permission.ACCELEROMETER）：去重力线加速度
   *   → uKick 抛甩脉冲，'game' 档更快捕捉挥动。任一失败仅记日志降级，
   *   不影响另一路与画面本身 */
  private syncSensor(): void {
    const want = this.active && !this.disposed && this.ready;
    if (want && !this.orientationOn) {
      try {
        // 每次进入舞台重取 alpha 基准：滚转是相对量，避免跨次残留跳变
        this.spinBase = null;
        const cb = (data: sensor.OrientationResponse): void => {
          const norm = normalizeTilt(data.beta, data.gamma);
          // 低通：事件率 16Hz 下 ~0.2s 收敛，滤手抖
          this.tiltX += (norm[0] - this.tiltX) * 0.12;
          this.tiltY += (norm[1] - this.tiltY) * 0.12;
          if (this.spinBase === null && Number.isFinite(data.alpha)) {
            this.spinBase = data.alpha;
          }
          if (this.spinBase !== null) {
            const target = normalizeSpin(wrapAngleDelta(data.alpha, this.spinBase));
            this.spin += (target - this.spin) * 0.15;
          }
          if (!this.tiltLogged) {
            this.tiltLogged = true;
            hilog.info(0x0004, 'VizView', 'orientation live, tilt=%{public}s spinBase=%{public}s',
              `${norm[0].toFixed(2)},${norm[1].toFixed(2)}`, `${this.spinBase}`);
          }
        };
        sensor.on(sensor.SensorId.ORIENTATION, cb, { interval: 'ui' });
        this.orientationOn = true;
      } catch (err) {
        hilog.warn(0x0004, 'VizView', 'orientation subscribe failed: %{public}s',
          JSON.stringify(err));
      }
    } else if (!want && this.orientationOn) {
      try {
        // 不带 callback 注销本类型全部订阅（本组件只注册一份）
        sensor.off(sensor.SensorId.ORIENTATION);
      } catch (err) {
        // 反订阅失败无需处理（组件销毁后系统自行回收）
      }
      this.orientationOn = false;
      this.spinBase = null;
    }
    if (want && !this.accelOn) {
      try {
        const cb = (data: sensor.LinearAccelerometerResponse): void => {
          const level = accelKickLevel(data.x, data.y, data.z);
          // attack：瞬时抬升只上不下，decay 在 frame() 里按时钟做
          if (level > this.kick) {
            this.kick = level;
          }
        };
        sensor.on(sensor.SensorId.LINEAR_ACCELEROMETER, cb, { interval: 'game' });
        this.accelOn = true;
      } catch (err) {
        // 权限被拒/无传感器：降级为纯姿态响应，画面不受影响
        hilog.warn(0x0004, 'VizView', 'linear-accel subscribe failed, kick disabled: %{public}s',
          JSON.stringify(err));
      }
    } else if (!want && this.accelOn) {
      try {
        sensor.off(sensor.SensorId.LINEAR_ACCELEROMETER);
      } catch (err) {
        // 反订阅失败无需处理（组件销毁后系统自行回收）
      }
      this.accelOn = false;
      this.kick = 0;
    }
  }

  private syncState(): void {
    // 倾斜订阅跟随舞台激活态：只在 full 变体且 active 时耗传感器
    this.syncSensor();
    this.syncMic();
    if (this.disposed) {
      return;
    }
    if (!this.active) {
      this.stopLoop();
      return;
    }
    const id = this.songId;
    if (id !== this.lastSongId) {
      this.lastSongId = id;
      this.seed = seedFromId(id);
      this.beatPhase = (this.seed % 997) / 997;
      this.playClock = 0;
      this.lastNow = Date.now();
    }
    if (id === '') {
      this.stopLoop();
      return;
    }
    if (this.isPlaying) {
      this.startLoop();
    } else if (!this.vizReady) {
      // 编译期间暂停态也保持帧循环：占位呼吸与"编译完成检测"都靠它驱动，
      // 否则暂停时切入可视化，占位静止且就绪检测永不触发
      this.startLoop();
    } else {
      this.fadeDeadline = Date.now() + FADE_MS;
    }
  }

  private startLoop(): void {
    if (this.running || this.ds === null || !this.ready) {
      return;
    }
    this.running = true;
    this.lastNow = Date.now();
    this.ds.start();
  }

  private stopLoop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    if (this.ds !== null) {
      this.ds.stop();
    }
  }

  /** 外部 presetIndex 变化时同步到渲染用的 presetLock */
  @Monitor('presetIndex')
  onPresetIndexChange(): void {
    const next = ((this.presetIndex % PRESET_COUNT) + PRESET_COUNT) % PRESET_COUNT;
    if (next !== this.presetLock) {
      this.presetTrans = 0;   // 风格变化：启动渐入过渡（不清空反馈画布）
    }
    this.presetLock = next;
  }

  private frame(): void {
    if (this.disposed || !this.ready) {
      return;
    }
    const now = Date.now();
    // 真机高刷屏上 displaySync 可能超预期回调，按场景间隔节流绘制
    // （full 用场景级帧间隔，aurora 40ms=25fps——慢场景无感、负载降一档）
    const minInterval = VIZ_FRAME_INTERVAL_MS[this.presetLock] ?? FRAME_MIN_INTERVAL;
    if (now - this.lastNow < minInterval) {
      return;
    }
    const dt = Math.min(now - this.lastNow, 66);
    this.lastNow = now;
    const playing = this.isPlaying;
    if (playing) {
      this.playClock += dt;
    }
    const t = this.playClock;
    // shader 管线上屏（XComponent 原生表面，fragment 逐像素解算——
    // 运算量与像素数相关、与效果复杂度无关，参数驱动）。帧驱动沿用
    // displaySync 节流；暂停时不渲染即冻结帧。
    // 音乐律动参数：麦克风律动开启且环境声有效时用真频谱（外放场景可视化
    // 随真实音乐跳动），否则按种子+时间确定性合成（平台无频谱 API）：
    // beat 节拍包络 / bass 低频段 / treble 高频段，仅驱动 shader 局部元素
    const mic = appStore.mic;
    let beat: number;
    let bass: number;
    let treble: number;
    if (this.micLive && mic.active && mic.valid) {
      beat = mic.levels.beat;
      bass = mic.levels.bass;
      treble = mic.levels.treble;
    } else {
      beat = beatEnvelope(t, bpmFromSeed(this.seed), this.beatPhase);
      const spec = synthSpectrum(this.seed, t, 8);
      bass = (spec[0] + spec[1]) / 2;
      treble = (spec[6] + spec[7]) / 2;
    }
    if (this.presetTrans < 1) {
      this.presetTrans = Math.min(1, this.presetTrans + dt / 1500);
    }
    // 抛甩包络 decay：attack 由传感器回调抬升，这里按有效播放时钟外的时间
    // 常数指数回落（暂停时 kick 冻结，随画面一起定格）
    if (this.kick > 0) {
      this.kick *= Math.exp(-dt / VisualizerView.KICK_DECAY_MS);
      if (this.kick < 0.01) {
        this.kick = 0;
      }
    }
    const drew: boolean = entry.renderFrame(t, this.seed, beat, bass, treble,
      this.presetLock, this.presetTrans, this.tiltX, this.tiltY, this.spin, this.kick);
    // 占位柔光呼吸：正弦涨落 0.35~0.6（周期 ~1.6s，只动亮度，防闪烁合规）
    if (!this.vizReady) {
      this.placeholderBreath = 0.475 + 0.125 * Math.sin(now / 260);
    }
    // 首个成功绘制的帧 = 后台编译完成：撤下编译中占位（淡出）
    if (drew && !this.vizReady) {
      this.vizReady = true;
      this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
        this.placeholderOn = false;
      });
    }
    if (!playing && now > this.fadeDeadline) {
      // 占位还在时不自动停帧（呼吸与就绪检测靠循环驱动），撤占位后恢复原逻辑
      if (this.placeholderOn) {
        this.fadeDeadline = now + FADE_MS;
      } else {
        this.stopLoop();
      }
    }
  }

  build() {
    // shader 渲染原生表面。XComponent(SURFACE) + EGL/GLES，
    // fragment shader 逐像素解算全部效果——运算量固定、参数驱动，
    // 无 Canvas 分块/位图放大等 CPU 管线与伪影。
    // 注意：XComponent 原生表面区域不接受点击语义——可视化舞台的点击
    // （回封面）由 PlayerPage 在前景层的舞台占位 Blank 上承担，见其注释
    Stack({ alignContent: Alignment.TopStart }) {
      XComponent({
        id: 'viz_full',
        type: XComponentType.SURFACE,
        libraryname: 'entry'
      })
        .width('100%')
        .height('100%')
        .onLoad((context) => {
          // 官方模板桥接：把 __NATIVE_XCOMPONENT_OBJ__ 包装对象传给 NAPI，
          // native 侧 napi_unwrap 解出 OH_NativeXComponent* 再注册回调
          entry.registerXComponent((context as XComponentVizContext).__NATIVE_XCOMPONENT_OBJ__);
          // 渲染管线就绪(原 Canvas 路径由 onReady 置位, XComponent 无对应事件):
          // 立即启动帧循环, 正在播放时画面即刻出现
          this.ready = true;
          this.syncState();
        })
      // 编译中占位：场景 program 在子线程编译的窗口期（挂载后几百毫秒）
      // 遮住空屏——恒暗舞台底 + 中央柔光缓慢呼吸，暗示"正在点亮"；
      // 首个绘制帧后 300ms 淡出。不叠任何文字/图标，避免抢戏。
      // 呼吸动画防闪烁合规：只动亮度，色相恒定
      if (this.placeholderOn) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('62%')
            .aspectRatio(1)
            .radialGradient({
              center: ['50%', '50%'],
              radius: '62%',
              colors: [[$r('app.color.viz_line'), 0], [$r('app.color.viz_fg_faint'), 1]]
            })
            .opacity(this.placeholderBreath)
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.viz_fg_faint'))
        .opacity(this.vizReady ? 0 : 1)
        .visibility(this.vizReady ? Visibility.Hidden : Visibility.Visible)
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
