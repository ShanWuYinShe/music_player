/**
 * Shader Playground · music_player
 *
 * 在本地浏览器里复刻移动端 XComponent + GLES3 可视化管线：
 *   - 4 个 GLSL ES 1.00 fragment shader 源文件直接来自
 *     music_app/entry/src/main/cpp/shaders/，磁盘版与构建版同源
 *   - WebGL2（仍是 GLSL ES 1.00 兼容子集）跑同一段 GLSL
 *   - 反馈纹理 ping-pong + 内部降采样 (render scale)
 *   - 复刻 VisualizerCore 的 beat / bass / treble 合成
 *
 * 与手机端差异（仅方便本地调参，渲染内容应一致）：
 *   - 暂停/恢复、参数滑杆、随机 seed、截图、实时错误浮层
 *   - 编辑器与预览并排，编辑保存（Cmd/Ctrl+S）即重编译
 */

const PRESETS = [
  { id: 0, file: 'fractal.frag', name: 'fractal', label: '分形漩涡' },
  { id: 1, file: 'pan.frag',     name: 'pan',     label: '炒锅水珠' },
  { id: 2, file: 'aurora.frag',  name: 'aurora',  label: '极光' },
  { id: 3, file: 'mirror.frag',  name: 'mirror',  label: '镜屋' },
];

// 与 VisualizerCore.ets 保持完全一致的纯函数实现
const FNV_OFFSET = 0x811c9dc5 >>> 0;
const FNV_PRIME = 0x01000193;

function fnv1a(str) {
  let h = FNV_OFFSET;
  for (let i = 0; i < str.length; i++) {
    h = Math.imul(h ^ str.charCodeAt(i), FNV_PRIME) >>> 0;
  }
  return h;
}

function hash01(n) {
  let h = (Math.imul((n | 0) ^ ((n | 0) >>> 16), 0x45d9f3b)) >>> 0;
  h = (Math.imul(h ^ (h >>> 16), 0x45d9f3b)) >>> 0;
  return (h >>> 8) / 0x1000000;
}

function seedFromId(id) {
  return fnv1a(id);
}

function bpmFromSeed(seed) {
  return 90 + Math.floor(hash01((seed + 0x5f3a) | 0) * 61);
}

function beatEnvelope(tMs, bpm, phase) {
  const periodMs = 60000 / Math.max(40, Math.min(220, bpm));
  let x = (tMs / periodMs) % 1;
  if (x < 0) x += 1;
  x = (x + phase) % 1;
  return 0.25 + 0.75 * Math.exp(-4 * x);
}

function synthSpectrum(seed, tMs, count) {
  const out = new Array(count);
  for (let i = 0; i < count; i++) {
    const p = count > 1 ? i / (count - 1) : 0;
    const base = 0.34 + 0.38 * (1 - p);
    const w1 = 0.0021 + 0.0035 * p;
    const w2 = 0.0009 + 0.0022 * p;
    const ph1 = hash01(seed + i * 7 + 1) * Math.PI * 2;
    const ph2 = hash01(seed + i * 13 + 5) * Math.PI * 2;
    const amp1 = 0.30 + 0.22 * hash01(seed + i * 29 + 11);
    const amp2 = 0.14 + 0.16 * hash01(seed + i * 41 + 17);
    const v = base + amp1 * Math.sin(tMs * w1 + ph1) + amp2 * Math.sin(tMs * w2 + ph2);
    out[i] = Math.min(1, Math.max(0.04, v));
  }
  return out;
}

// ============================================================
// GLSL ES 1.00 → WebGL2 patch
// ============================================================

// 工具自带的 GLSL 头：精度、varying、uniform 与输出变量
// WebGL2 必须以 `#version 300 es` 开头才会被解析为 GLSL ES 3.00（否则按 1.00 处理）
const VERSION_DIRECTIVE = '#version 300 es\n';

const FRAG_HEADER =
  VERSION_DIRECTIVE +
  'precision highp float;\n' +
  'uniform float uT;\n' +
  'uniform float uSeed;\n' +
  'uniform vec2 uRes;\n' +
  'uniform float uBeat;\n' +
  'uniform float uBass;\n' +
  'uniform float uTreble;\n' +
  'uniform float uTransition;\n' +
  'uniform sampler2D uPrev;\n' +
  'in vec2 vUV;\n' +
  'out vec4 fragColor;\n';

const VERT_HEADER =
  VERSION_DIRECTIVE +
  'precision highp float;\n' +
  'in vec2 aPos;\n' +
  'out vec2 vUV;\n';

const BLIT_HEADER =
  VERSION_DIRECTIVE +
  'precision highp float;\n' +
  'in vec2 vUV;\n' +
  'uniform sampler2D uTex;\n' +
  'out vec4 fragColor;\n';

const FRAG_UNIFORM_NAMES = [
  'uT', 'uSeed', 'uRes', 'uBeat', 'uBass', 'uTreble', 'uTransition', 'uPrev',
];
const BLIT_UNIFORM_NAMES = ['uTex'];

function escapeReg(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function buildUniformStripPattern(names) {
  const alt = names.map(escapeReg).join('|');
  return new RegExp('^\\s*uniform\\s+\\w+\\s+(?:' + alt + ')\\s*;\\s*\\n', 'gm');
}

const FRAG_UNIFORM_RE = buildUniformStripPattern(FRAG_UNIFORM_NAMES);
const BLIT_UNIFORM_RE = buildUniformStripPattern(BLIT_UNIFORM_NAMES);

function patchFragForWebGL2(src) {
  let s = src;
  s = s.replace(/^#version\s+100\s*\n/, '');
  s = s.replace(/^\s*precision\s+\w+\s+\w+\s*;\s*\n/gm, '');
  s = s.replace(FRAG_UNIFORM_RE, '');
  // fragment 的 `varying` 是输入，源文件里 `varying vec2 vUV;` 这种
  // 已经被工具头声明了，所以这里直接 strip 即可
  s = s.replace(/^\s*varying\s+[^;]+;\s*\n/gm, '');
  s = s.replace(/\btexture2D\s*\(/g, 'texture(');
  s = s.replace(/\battribute\s+/g, 'in ');
  s = s.replace(/\bgl_FragColor\b/g, 'fragColor');
  return FRAG_HEADER + s;
}

function patchVertForWebGL2(src) {
  let s = src;
  s = s.replace(/^#version\s+100\s*\n/, '');
  s = s.replace(/^\s*precision\s+\w+\s+\w+\s*;\s*\n/gm, '');
  // 源文件 vertex 头里只有 `attribute aPos` 与 `varying vUV`，由工具头统一声明
  s = s.replace(/^\s*(?:attribute|in)\s+vec2\s+aPos\s*;\s*\n/gm, '');
  s = s.replace(/^\s*varying\s+[^;]+;\s*\n/gm, '');
  s = s.replace(/\btexture2D\s*\(/g, 'texture(');
  return VERT_HEADER + s;
}

function patchBlitForWebGL2(src) {
  let s = src;
  s = s.replace(/^#version\s+100\s*\n/, '');
  s = s.replace(/^\s*precision\s+\w+\s+\w+\s*;\s*\n/gm, '');
  s = s.replace(BLIT_UNIFORM_RE, '');
  // blit 是 fragment stage，源文件里 `varying vec2 vUV;` 由工具头统一声明
  s = s.replace(/^\s*varying\s+[^;]+;\s*\n/gm, '');
  s = s.replace(/\btexture2D\s*\(/g, 'texture(');
  s = s.replace(/\battribute\s+/g, 'in ');
  s = s.replace(/\bgl_FragColor\b/g, 'fragColor');
  return BLIT_HEADER + s;
}

// ============================================================
// 状态
// ============================================================

const state = {
  presetIndex: 0,
  // 来自 URL ?preset=N 的初始 preset（仅在启动时生效；为 0..3）
  initialPreset: (() => {
    const m = location.search.match(/[?&]preset=(\d)/);
    const n = m ? parseInt(m[1], 10) : 0;
    return (n >= 0 && n < 4) ? n : 0;
  })(),
  sources: {},
  diskSources: {},
  dirty: {},

  seed: 12345678,
  bpm: 120,
  beatScale: 0.6,
  bassScale: 0.55,
  trebleScale: 0.5,
  transition: 1.0,
  renderScale: 0.67,
  targetFps: 30,
  paused: false,

  playClock: 0,
  lastWall: 0,
  beatPhase: 0,
  beatBoost: 0,

  gl: null,
  programs: [null, null, null, null],
  blitProgram: null,
  vertSrc: '',
  fbos: [null, null],
  texs: [null, null],
  fboW: 0,
  fboH: 0,
  flip: 0,
  locs: null,
  blitLoc: null,

  lastError: '',

  fps: 0,
  fpsCounter: 0,
  fpsLastUpdate: 0,
};

// ============================================================
// WebGL helpers
// ============================================================

function compileShader(gl, type, src, label) {
  const sh = gl.createShader(type);
  gl.shaderSource(sh, src);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    const log = gl.getShaderInfoLog(sh) || '(no log)';
    const lineMatch = log.match(/ERROR:\s*\d+:(\d+)/);
    const line = lineMatch ? parseInt(lineMatch[1], 10) : null;
    gl.deleteShader(sh);
    throw { kind: 'compile', label, log, line };
  }
  return sh;
}

function linkProgram(gl, vs, fs, label) {
  const p = gl.createProgram();
  gl.attachShader(p, vs);
  gl.attachShader(p, fs);
  gl.bindAttribLocation(p, 0, 'aPos');
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
    const log = gl.getProgramInfoLog(p) || '(no log)';
    gl.deleteProgram(p);
    throw { kind: 'link', label, log };
  }
  return p;
}

function buildSceneProgram(gl, vertSrc, fragSrc, label) {
  const vs = compileShader(gl, gl.VERTEX_SHADER, vertSrc, `${label}.vert`);
  const fs = compileShader(gl, gl.FRAGMENT_SHADER, fragSrc, `${label}.frag`);
  const p = linkProgram(gl, vs, fs, label);
  gl.deleteShader(vs);
  gl.deleteShader(fs);
  return p;
}

function getSceneLocs(gl, p) {
  return {
    t: gl.getUniformLocation(p, 'uT'),
    seed: gl.getUniformLocation(p, 'uSeed'),
    res: gl.getUniformLocation(p, 'uRes'),
    beat: gl.getUniformLocation(p, 'uBeat'),
    bass: gl.getUniformLocation(p, 'uBass'),
    treble: gl.getUniformLocation(p, 'uTreble'),
    transition: gl.getUniformLocation(p, 'uTransition'),
    prev: gl.getUniformLocation(p, 'uPrev'),
  };
}

// ============================================================
// 渲染器
// ============================================================

const canvas = document.getElementById('gl');
const gl = canvas.getContext('webgl2', {
  alpha: false,
  antialias: false,
  preserveDrawingBuffer: true,
  premultipliedAlpha: false,
});
if (!gl) {
  document.getElementById('status').textContent = 'WebGL2 不可用';
  document.getElementById('status').className = 'status err';
  throw new Error('WebGL2 not supported');
}
state.gl = gl;

const kQuad = new Float32Array([-1, -1, 3, -1, -1, 3]);
const vbo = gl.createBuffer();
gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
gl.bufferData(gl.ARRAY_BUFFER, kQuad, gl.STATIC_DRAW);
const vao = gl.createVertexArray();
gl.bindVertexArray(vao);
gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
gl.enableVertexAttribArray(0);
gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
gl.bindVertexArray(null);

function createFbPair(w, h) {
  const texs = [gl.createTexture(), gl.createTexture()];
  const fbos = [gl.createFramebuffer(), gl.createFramebuffer()];
  for (let i = 0; i < 2; i++) {
    gl.bindTexture(gl.TEXTURE_2D, texs[i]);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbos[i]);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texs[i], 0);
  }
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  return { texs, fbos };
}

function ensureFboSize(w, h) {
  w = Math.max(1, Math.floor(w));
  h = Math.max(1, Math.floor(h));
  if (state.fboW === w && state.fboH === h && state.texs[0]) return;
  if (state.texs[0]) {
    gl.deleteTexture(state.texs[0]);
    gl.deleteTexture(state.texs[1]);
    gl.deleteFramebuffer(state.fbos[0]);
    gl.deleteFramebuffer(state.fbos[1]);
  }
  const { texs, fbos } = createFbPair(w, h);
  state.texs = texs;
  state.fbos = fbos;
  state.fboW = w;
  state.fboH = h;
  state.flip = 0;
}

function setStatus(text, kind) {
  const el = document.getElementById('status');
  el.textContent = text;
  el.className = 'status' + (kind ? ' ' + kind : '');
}

function showCompileError(err) {
  const overlay = document.getElementById('compile-overlay');
  const logEl = document.getElementById('overlay-log');
  const titleEl = document.getElementById('overlay-title');
  titleEl.textContent = `编译错误 · ${err.label}`;
  logEl.textContent = err.log;
  overlay.classList.remove('hidden');
  setStatus(`编译失败: ${err.label}`, 'err');
  state.lastError = err.log;
}

function hideCompileError() {
  document.getElementById('compile-overlay').classList.add('hidden');
  state.lastError = '';
}

function compileAllShaders() {
  // blit 先编译
  try {
    const blitSrc = patchBlitForWebGL2(state.sources['blit.frag']);
    const vs = compileShader(gl, gl.VERTEX_SHADER, state.vertSrc, 'visualizer.vert');
    const fs = compileShader(gl, gl.FRAGMENT_SHADER, blitSrc, 'blit.frag');
    const newBlit = linkProgram(gl, vs, fs, 'blit');
    gl.deleteShader(vs);
    gl.deleteShader(fs);
    if (state.blitProgram) gl.deleteProgram(state.blitProgram);
    state.blitProgram = newBlit;
    state.blitLoc = { uTex: gl.getUniformLocation(newBlit, 'uTex') };
  } catch (err) {
    if (state.blitProgram) {
      gl.deleteProgram(state.blitProgram);
      state.blitProgram = null;
    }
    showCompileError(err);
    return false;
  }

  for (const preset of PRESETS) {
    try {
      const src = state.sources[preset.file];
      const fragSrc = patchFragForWebGL2(src);
      const p = buildSceneProgram(gl, state.vertSrc, fragSrc, preset.name);
      if (state.programs[preset.id]) {
        gl.deleteProgram(state.programs[preset.id]);
      }
      state.programs[preset.id] = p;
      state.locs = state.locs || [];
      state.locs[preset.id] = getSceneLocs(gl, p);
    } catch (err) {
      if (state.programs[preset.id]) {
        gl.deleteProgram(state.programs[preset.id]);
        state.programs[preset.id] = null;
      }
      showCompileError(err);
      return false;
    }
  }
  hideCompileError();
  setStatus('编译成功', 'ok');
  return true;
}

function drawFrame() {
  if (!state.programs[state.presetIndex] || !state.blitProgram) {
    return;
  }
  const dpr = window.devicePixelRatio || 1;
  const cssW = canvas.clientWidth;
  const cssH = canvas.clientHeight;
  const targetW = Math.max(1, Math.floor(cssW * dpr));
  const targetH = Math.max(1, Math.floor(cssH * dpr));
  if (canvas.width !== targetW || canvas.height !== targetH) {
    canvas.width = targetW;
    canvas.height = targetH;
  }
  const fboW = Math.max(1, Math.floor(targetW * state.renderScale));
  const fboH = Math.max(1, Math.floor(targetH * state.renderScale));
  ensureFboSize(fboW, fboH);

  const t = state.playClock;
  const beat = Math.min(1, beatEnvelope(t, state.bpm, state.beatPhase) * state.beatScale + state.beatBoost);
  const spec = synthSpectrum(state.seed, t, 8);
  const bass = Math.min(1, ((spec[0] + spec[1]) / 2) * state.bassScale + state.beatBoost * 0.4);
  const treble = Math.min(1, ((spec[6] + spec[7]) / 2) * state.trebleScale + state.beatBoost * 0.3);

  // Pass A: scene + 反馈 -> 当前 FBO
  gl.bindFramebuffer(gl.FRAMEBUFFER, state.fbos[state.flip]);
  gl.viewport(0, 0, state.fboW, state.fboH);
  gl.bindVertexArray(vao);
  const sceneP = state.programs[state.presetIndex];
  gl.useProgram(sceneP);
  const loc = state.locs[state.presetIndex];
  gl.uniform1f(loc.t, t);
  gl.uniform1f(loc.seed, state.seed);
  gl.uniform2f(loc.res, state.fboW, state.fboH);
  gl.uniform1f(loc.beat, beat);
  gl.uniform1f(loc.bass, bass);
  gl.uniform1f(loc.treble, treble);
  gl.uniform1f(loc.transition, state.transition);
  gl.activeTexture(gl.TEXTURE0);
  gl.bindTexture(gl.TEXTURE_2D, state.texs[1 - state.flip]);
  gl.uniform1i(loc.prev, 0);
  gl.drawArrays(gl.TRIANGLES, 0, 3);

  // Pass B: FBO -> 屏幕
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  gl.viewport(0, 0, canvas.width, canvas.height);
  gl.useProgram(state.blitProgram);
  gl.activeTexture(gl.TEXTURE0);
  gl.bindTexture(gl.TEXTURE_2D, state.texs[state.flip]);
  gl.uniform1i(state.blitLoc.uTex, 0);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  gl.bindVertexArray(null);
  state.flip = 1 - state.flip;
}

// ============================================================
// 主循环
// ============================================================

function tick() {
  if (!state.paused) {
    const now = performance.now();
    const dt = Math.min(state.lastWall === 0 ? 16 : now - state.lastWall, 66);
    state.lastWall = now;
    state.playClock += dt;

    if (state.beatBoost > 0) {
      state.beatBoost = Math.max(0, state.beatBoost - dt / 280);
    }
  } else {
    state.lastWall = performance.now();
  }
  drawFrame();

  state.fpsCounter++;
  if (state.fpsLastUpdate === 0) state.fpsLastUpdate = performance.now();
  const elapsed = performance.now() - state.fpsLastUpdate;
  if (elapsed > 500) {
    state.fps = (state.fpsCounter * 1000) / elapsed;
    state.fpsCounter = 0;
    state.fpsLastUpdate = performance.now();
    document.getElementById('meta-fps').textContent = state.fps.toFixed(1) + ' fps';
    document.getElementById('meta-size').textContent = `${canvas.width}×${canvas.height}`;
    document.getElementById('meta-time').textContent = `t=${(state.playClock / 1000).toFixed(2)} s`;
  }

  const interval = 1000 / state.targetFps;
  setTimeout(tick, interval);
}

// ============================================================
// 文件加载
// ============================================================

async function loadShaderFiles() {
  setStatus('加载源文件…');
  const list = [...PRESETS.map(p => p.file), 'blit.frag', 'visualizer.vert'];
  try {
    const results = await Promise.all(
      list.map(async (name) => {
        const r = await fetch(`../music_app/entry/src/main/cpp/shaders/${name}`);
        if (!r.ok) throw new Error(`加载 ${name} 失败: ${r.status}`);
        return [name, await r.text()];
      })
    );
    for (const [name, text] of results) {
      state.sources[name] = text;
      state.diskSources[name] = text;
      state.dirty[name] = false;
    }
    state.vertSrc = patchVertForWebGL2(state.sources['visualizer.vert']);
    setStatus('源文件已加载', 'ok');
  } catch (err) {
    setStatus('加载失败: ' + err.message, 'err');
    throw err;
  }
}

// ============================================================
// UI
// ============================================================

const editor = document.getElementById('editor');
const lineNumbers = document.getElementById('line-numbers');
const editorFilename = document.getElementById('editor-filename');
const dirtyFlag = document.getElementById('dirty-flag');

function updateLineNumbers() {
  const lines = editor.value.split('\n').length;
  let s = '';
  for (let i = 1; i <= lines; i++) s += i + '\n';
  lineNumbers.textContent = s;
}

function updateDirtyFlag() {
  const fn = PRESETS[state.presetIndex].file;
  dirtyFlag.textContent = state.dirty[fn] ? '（已修改，未保存到磁盘）' : '';
  dirtyFlag.style.color = state.dirty[fn] ? 'var(--warn)' : 'var(--fg-2)';
}

function selectPreset(idx) {
  // 切换到第 idx 个 preset。仅在「已加载完源 + 用户改过编辑器」时才把当前
  // editor 内容回写到 state.sources[cur.file]，避免初次启动 editor 还是空
  // 时把磁盘源覆盖成空串。
  const cur = PRESETS[state.presetIndex];
  if (cur && state.dirty[cur.file] && state.sources[cur.file] !== undefined) {
    state.sources[cur.file] = editor.value;
  }
  state.presetIndex = idx;
  editorFilename.textContent = PRESETS[idx].file;
  editor.value = state.sources[PRESETS[idx].file] || '';
  document.querySelectorAll('.file-list li').forEach((el, i) => {
    el.classList.toggle('active', i === idx);
  });
  updateLineNumbers();
  updateDirtyFlag();
}

editor.addEventListener('input', () => {
  const fn = PRESETS[state.presetIndex].file;
  state.sources[fn] = editor.value;
  const disk = state.diskSources[fn] || '';
  state.dirty[fn] = (editor.value !== disk);
  updateLineNumbers();
  updateDirtyFlag();
  if (autoReloadEl.checked) {
    scheduleRecompile();
  }
});

editor.addEventListener('scroll', () => {
  lineNumbers.scrollTop = editor.scrollTop;
});

editor.addEventListener('keydown', (e) => {
  if (e.key === 'Tab') {
    e.preventDefault();
    const start = editor.selectionStart;
    const end = editor.selectionEnd;
    editor.value = editor.value.slice(0, start) + '  ' + editor.value.slice(end);
    editor.selectionStart = editor.selectionEnd = start + 2;
    editor.dispatchEvent(new Event('input'));
  }
  if ((e.metaKey || e.ctrlKey) && e.key === 's') {
    e.preventDefault();
    compileAllShaders();
  }
});

document.querySelectorAll('.file-list li').forEach((el) => {
  el.addEventListener('click', () => {
    const idx = parseInt(el.dataset.preset, 10);
    selectPreset(idx);
  });
});

const autoReloadEl = document.getElementById('auto-reload');
let recompileTimer = null;
function scheduleRecompile() {
  if (recompileTimer) clearTimeout(recompileTimer);
  recompileTimer = setTimeout(() => {
    recompileTimer = null;
    compileAllShaders();
  }, 220);
}

document.getElementById('btn-reload').addEventListener('click', () => {
  compileAllShaders();
});

document.getElementById('btn-reset').addEventListener('click', () => {
  const fn = PRESETS[state.presetIndex].file;
  const disk = state.diskSources[fn];
  if (disk !== undefined) {
    state.sources[fn] = disk;
    editor.value = disk;
    state.dirty[fn] = false;
    updateLineNumbers();
    updateDirtyFlag();
    compileAllShaders();
  }
});

document.getElementById('btn-screenshot').addEventListener('click', () => screenshot());
document.getElementById('btn-close-overlay').addEventListener('click', () => hideCompileError());

function bindRange(id, key, valId, fmt) {
  const el = document.getElementById(id);
  const val = document.getElementById(valId);
  const apply = () => {
    let v = parseFloat(el.value);
    if (id === 'ctl-seed') v = v >>> 0;
    // 百分比类（0-100 的滑杆）需要在 state 里以 0..1 存储
    if (id === 'ctl-scale' || id === 'ctl-beat' || id === 'ctl-bass' ||
        id === 'ctl-treble' || id === 'ctl-trans') {
      v = v / 100;
    }
    state[key] = v;
    val.textContent = fmt(v);
  };
  el.addEventListener('input', apply);
  apply();
}

bindRange('ctl-seed', 'seed', 'val-seed', (v) => (v >>> 0).toString(10));
bindRange('ctl-bpm', 'bpm', 'val-bpm', (v) => v.toFixed(0));
bindRange('ctl-beat', 'beatScale', 'val-beat', (v) => v.toFixed(2));
bindRange('ctl-bass', 'bassScale', 'val-bass', (v) => v.toFixed(2));
bindRange('ctl-treble', 'trebleScale', 'val-treble', (v) => v.toFixed(2));
bindRange('ctl-trans', 'transition', 'val-trans', (v) => v.toFixed(2));
bindRange('ctl-scale', 'renderScale', 'val-scale', (v) => v.toFixed(2) + '×');
bindRange('ctl-fps', 'targetFps', 'val-fps', (v) => v.toFixed(0));

document.getElementById('ctl-pause').addEventListener('change', (e) => {
  state.paused = e.target.checked;
  document.getElementById('val-pause').textContent = state.paused ? '已暂停' : '运行中';
});

document.getElementById('btn-tap-beat').addEventListener('click', () => {
  state.beatBoost = Math.min(1, state.beatBoost + 0.6);
});

document.getElementById('btn-random-seed').addEventListener('click', () => {
  const id = `${Date.now()}-${Math.floor(Math.random() * 1e9)}`;
  state.seed = seedFromId(id);
  state.beatPhase = (state.seed % 997) / 997;
  state.playClock = 0;
  document.getElementById('ctl-seed').value = state.seed;
  document.getElementById('val-seed').textContent = state.seed.toString(10);
});

document.getElementById('ctl-bpm').addEventListener('input', () => {
  state.beatPhase = 0;
});

canvas.addEventListener('click', () => {
  const next = (state.presetIndex + 1) % PRESETS.length;
  selectPreset(next);
});

function screenshot() {
  if (state.paused) drawFrame();
  canvas.toBlob((blob) => {
    if (!blob) return;
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `screenshot-${PRESETS[state.presetIndex].name}-${Date.now()}.png`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  }, 'image/png');
}

window.addEventListener('keydown', (e) => {
  if (e.target === editor) return;
  if (e.key === ' ') {
    e.preventDefault();
    state.paused = !state.paused;
    document.getElementById('ctl-pause').checked = state.paused;
    document.getElementById('val-pause').textContent = state.paused ? '已暂停' : '运行中';
  } else if (e.key === 's' || e.key === 'S') {
    screenshot();
  } else if (e.key === 'Escape') {
    hideCompileError();
  } else if (e.key === '1' || e.key === '2' || e.key === '3' || e.key === '4') {
    const idx = parseInt(e.key, 10) - 1;
    if (idx >= 0 && idx < PRESETS.length) selectPreset(idx);
  }
});

// ============================================================
// 启动
// ============================================================

(async function main() {
  try {
    await loadShaderFiles();
    selectPreset(state.initialPreset);
    compileAllShaders();
    tick();
  } catch (err) {
    setStatus('启动失败: ' + err.message, 'err');
    console.error(err);
  }
})();
