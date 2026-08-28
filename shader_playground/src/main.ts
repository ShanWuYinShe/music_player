/**
 * Shader Playground 入口：装配渲染器 / 编辑器 / 拖拽 / UI。
 *
 * 在浏览器里复刻移动端 XComponent + GLES3 可视化管线：
 *   - GLSL ES 1.00 源文件经 Vite 中间件直接读自
 *     music_app/entry/src/main/cpp/shaders/，磁盘版与构建版同源
 *   - WebGL2（GLSL ES 3.00 兼容头）跑同一段 GLSL，反馈纹理 ping-pong
 *     + 内部降采样与 visualizer.cpp 一一对应
 *   - 音乐律动参数来自与 VisualizerCore.ets 完全等价的 JS 实现
 *
 * 便于本地调参的差异：暂停/滑杆/随机 seed/截图/拖拽载入/实时错误浮层。
 * 编辑器改动只影响浏览器预览，不会写回磁盘。
 */
import { AudioSim, seedFromId } from './audioSim';
import { installDnd, type LoadedFile } from './dnd';
import { createEditor } from './editor';
import { type Diagnostic, toDiagnostic } from './errors';
import { BLIT_FILE, PRESETS, VERT_FILE } from './presets';
import { VizRenderer } from './renderer';

// ============================================================
// 状态
// ============================================================

const state = {
	presetIndex: (() => {
		const m = location.search.match(/[?&]preset=(\d)/);
		const n = m?.[1] ? parseInt(m[1], 10) : 0;
		return n >= 0 && n < PRESETS.length ? n : 0;
	})(),
	sources: {} as Record<string, string>,
	diskSources: {} as Record<string, string>,
	dirty: {} as Record<string, boolean>,

	transition: 1.0,
	renderScale: 0.67,
	targetFps: 30,
	paused: false,

	lastWall: 0,
};

const audio = new AudioSim();
audio.seed = 12345678;
audio.bpm = 120;

const $ = <T extends HTMLElement>(id: string): T => {
	const el = document.getElementById(id);
	if (!el) throw new Error(`页面缺少 #${id}，请检查 index.html`);
	return el as T;
};

// ============================================================
// 渲染器与编辑器
// ============================================================

const canvas = $('gl') as HTMLCanvasElement;

let renderer: VizRenderer;
try {
	renderer = new VizRenderer(canvas);
} catch (err) {
	setStatusText(toDiagnostic(err, '初始化').log);
	throw err;
}

let suppressDocChange = false;
const editor = createEditor($('editor'), {
	onDocChanged(text) {
		if (suppressDocChange) return;
		const file = currentFile();
		state.sources[file] = text;
		state.dirty[file] = text !== (state.diskSources[file] ?? '');
		updateDirtyFlag();
		if (autoReloadEl.checked) scheduleRecompile();
	},
	onSave() {
		compileAllShaders();
		return true;
	},
});

// ============================================================
// 编译与错误浮层
// ============================================================

function setStatusText(text: string, kind?: 'ok' | 'err'): void {
	const el = $('status');
	el.textContent = text;
	el.className = 'status' + (kind ? ` ${kind}` : '');
}

function showDiagnostic(diag: Diagnostic): void {
	$('overlay-title').textContent = diag.title;
	$('overlay-log').textContent = diag.log;
	$('compile-overlay').classList.remove('hidden');
	setStatusText(diag.title, 'err');
}

function hideDiagnostic(): void {
	$('compile-overlay').classList.add('hidden');
}

function currentFile(): string {
	return presetAt(state.presetIndex).file;
}

/** 越界的 preset 索引属于程序错误，直接抛出而不是静默 undefined */
function presetAt(idx: number) {
	const p = PRESETS[idx];
	if (!p) throw new Error(`preset ${idx} 不存在`);
	return p;
}

function compileAllShaders(): void {
	if (Object.keys(state.sources).length === 0) {
		setStatusText('源文件尚未载入', 'err');
		return;
	}
	const diag = renderer.compileAll(state.sources);
	if (diag) {
		showDiagnostic(diag);
	} else {
		hideDiagnostic();
		setStatusText('编译成功', 'ok');
	}
}

let recompileTimer: ReturnType<typeof setTimeout> | null = null;
function scheduleRecompile(): void {
	if (recompileTimer) clearTimeout(recompileTimer);
	recompileTimer = setTimeout(() => {
		recompileTimer = null;
		compileAllShaders();
	}, 220);
}

// ============================================================
// preset / 编辑器联动
// ============================================================

function updateDirtyFlag(): void {
	const file = currentFile();
	const dirty = state.dirty[file] ?? false;
	const flag = $('dirty-flag');
	flag.textContent = dirty ? '（已修改，未保存到磁盘）' : '';
	flag.style.color = dirty ? 'var(--warn)' : 'var(--fg-2)';
}

function selectPreset(idx: number): void {
	// 注意：这里不把编辑器内容"保存"回 sources——编辑器的 onDocChanged
	// 才是唯一写入方；若在这里回写，会把拖入/程序化载入的新源码用旧编辑器
	// 内容覆盖掉（脏标记下的陈旧回写）。
	state.presetIndex = idx;
	const next = presetAt(idx);
	$('editor-filename').textContent = next.file;
	suppressDocChange = true;
	editor.setText(state.sources[next.file] ?? '');
	suppressDocChange = false;
	document.querySelectorAll<HTMLLIElement>('#file-list li').forEach((el, i) => {
		el.classList.toggle('active', i === idx);
	});
	updateDirtyFlag();
}

// ============================================================
// 源文件载入（dev 由 Vite 中间件提供，preview/build 由静态拷贝提供）
// ============================================================

async function fetchShaderText(name: string): Promise<string> {
	const r = await fetch(`/shaders/${name}`, { cache: 'no-store' });
	if (!r.ok) throw new Error(`加载 ${name} 失败: HTTP ${r.status}`);
	return r.text();
}

function applySource(name: string, text: string): void {
	state.sources[name] = text;
	state.diskSources[name] = text;
	state.dirty[name] = false;
}

/** 拖入 / 手动编辑产生的会话内源码：不落盘，dirty 相对磁盘基线 */
function setSessionSource(name: string, text: string): void {
	state.sources[name] = text;
	state.dirty[name] = text !== (state.diskSources[name] ?? '');
}

async function loadAllShaderFiles(): Promise<void> {
	setStatusText('加载源文件…');
	const names = [...PRESETS.map((p) => p.file), BLIT_FILE, VERT_FILE];
	const results = await Promise.all(
		names.map(async (name) => [name, await fetchShaderText(name)] as const),
	);
	for (const [name, text] of results) applySource(name, text);
	setStatusText('源文件已加载', 'ok');
}

/** 「重载选中」：从磁盘重新读取当前文件（手机端构建用的就是这份） */
async function reloadCurrentFromDisk(): Promise<void> {
	const file = currentFile();
	try {
		const text = await fetchShaderText(file);
		applySource(file, text);
		if (presetAt(state.presetIndex).file === file) {
			suppressDocChange = true;
			editor.setText(text);
			suppressDocChange = false;
		}
		updateDirtyFlag();
		compileAllShaders();
	} catch (err) {
		showDiagnostic(toDiagnostic(err, `重读 ${file}`));
	}
}

function resetCurrentToDisk(): void {
	const file = currentFile();
	const disk = state.diskSources[file];
	if (disk === undefined) return;
	applySource(file, disk);
	suppressDocChange = true;
	editor.setText(disk);
	suppressDocChange = false;
	updateDirtyFlag();
	compileAllShaders();
}

/** 拖入文件分发：.vert → 顶点源；blit.frag → blit；其余 .frag 按顺序填入场景槽 */
function handleDroppedFiles(files: LoadedFile[]): void {
	let slot = state.presetIndex;
	let firstSlot: number | null = null;
	for (const f of files) {
		const name = f.name.toLowerCase();
		if (name === VERT_FILE || name.endsWith('.vert')) {
			setSessionSource(VERT_FILE, f.text);
			continue;
		}
		if (name === BLIT_FILE) {
			setSessionSource(BLIT_FILE, f.text);
			continue;
		}
		setSessionSource(presetAt(slot).file, f.text);
		if (firstSlot === null) firstSlot = slot;
		slot = (slot + 1) % PRESETS.length;
	}
	if (firstSlot !== null) selectPreset(firstSlot);
	updateDirtyFlag();
	compileAllShaders();
}

// ============================================================
// 主循环
// ============================================================

let fps = 0;
let fpsCounter = 0;
let fpsLastUpdate = 0;

function renderFrame(): void {
	const { beat, bass, treble } = audio.sample();
	renderer.draw(state.presetIndex, {
		t: audio.playClock,
		seed: audio.seed,
		beat,
		bass,
		treble,
		transition: state.transition,
		renderScale: state.renderScale,
	});
}

function tick(): void {
	const now = performance.now();
	if (!state.paused) {
		const dt = Math.min(state.lastWall === 0 ? 16 : now - state.lastWall, 66);
		audio.advance(dt);
	}
	state.lastWall = now;
	renderFrame();

	fpsCounter++;
	if (fpsLastUpdate === 0) fpsLastUpdate = now;
	const elapsed = now - fpsLastUpdate;
	if (elapsed > 500) {
		fps = (fpsCounter * 1000) / elapsed;
		fpsCounter = 0;
		fpsLastUpdate = now;
		$('meta-fps').textContent = `${fps.toFixed(1)} fps`;
		$('meta-size').textContent = `${canvas.width}×${canvas.height}`;
		$('meta-time').textContent = `t=${(audio.playClock / 1000).toFixed(2)} s`;
	}
	setTimeout(tick, 1000 / state.targetFps);
}

// ============================================================
// 截图
// ============================================================

function screenshot(): void {
	if (state.paused) renderFrame();
	canvas.toBlob((blob) => {
		if (!blob) return;
		const url = URL.createObjectURL(blob);
		const a = document.createElement('a');
		a.href = url;
		a.download = `screenshot-${presetAt(state.presetIndex).name}-${Date.now()}.png`;
		a.click();
		setTimeout(() => URL.revokeObjectURL(url), 2000);
	}, 'image/png');
}

// ============================================================
// UI 绑定
// ============================================================

function setPaused(paused: boolean): void {
	state.paused = paused;
	$<HTMLInputElement>('ctl-pause').checked = paused;
	$('val-pause').textContent = paused ? '已暂停' : '运行中';
}

function bindRange(
	id: string,
	valId: string,
	apply: (v: number) => void,
	fmt: (v: number) => string,
	transform: (raw: number) => number = (v) => v,
): void {
	const el = $<HTMLInputElement>(id);
	const val = $(valId);
	const run = (): void => {
		const v = transform(parseFloat(el.value));
		apply(v);
		val.textContent = fmt(v);
	};
	el.addEventListener('input', run);
	run();
}

const autoReloadEl = $<HTMLInputElement>('auto-reload');

bindRange(
	'ctl-seed',
	'val-seed',
	(v) => audio.setSeed(v),
	(v) => (v >>> 0).toString(10),
	(v) => v >>> 0,
);
bindRange(
	'ctl-bpm',
	'val-bpm',
	(v) => {
		audio.bpm = v;
		audio.resetPhase();
	},
	(v) => v.toFixed(0),
);
bindRange(
	'ctl-beat',
	'val-beat',
	(v) => {
		audio.beatScale = v;
	},
	(v) => v.toFixed(2),
	(v) => v / 100,
);
bindRange(
	'ctl-bass',
	'val-bass',
	(v) => {
		audio.bassScale = v;
	},
	(v) => v.toFixed(2),
	(v) => v / 100,
);
bindRange(
	'ctl-treble',
	'val-treble',
	(v) => {
		audio.trebleScale = v;
	},
	(v) => v.toFixed(2),
	(v) => v / 100,
);
bindRange(
	'ctl-trans',
	'val-trans',
	(v) => {
		state.transition = v;
	},
	(v) => v.toFixed(2),
	(v) => v / 100,
);
bindRange(
	'ctl-scale',
	'val-scale',
	(v) => {
		state.renderScale = v;
	},
	(v) => `${v.toFixed(2)}×`,
	(v) => v / 100,
);
bindRange(
	'ctl-fps',
	'val-fps',
	(v) => {
		state.targetFps = v;
	},
	(v) => v.toFixed(0),
);

$('ctl-pause').addEventListener('change', (e) => {
	setPaused((e.target as HTMLInputElement).checked);
});
$('btn-tap-beat').addEventListener('click', () => audio.tapBeat());
$('btn-random-seed').addEventListener('click', () => {
	audio.setSeed(seedFromId(`${Date.now()}-${Math.floor(Math.random() * 1e9)}`));
	syncSeedSlider();
});
$('btn-reload').addEventListener('click', () => void reloadCurrentFromDisk());
$('btn-reset').addEventListener('click', () => resetCurrentToDisk());
$('btn-screenshot').addEventListener('click', () => screenshot());
$('btn-close-overlay').addEventListener('click', () => hideDiagnostic());

function syncSeedSlider(): void {
	const el = $<HTMLInputElement>('ctl-seed');
	el.value = String(audio.seed);
	$('val-seed').textContent = audio.seed.toString(10);
}

// 文件列表（由 PRESETS 生成）
const fileList = $('file-list');
for (const p of PRESETS) {
	const li = document.createElement('li');
	li.dataset.preset = String(p.id);
	if (p.id === state.presetIndex) li.classList.add('active');
	li.innerHTML =
		`<span class="dot" style="--c:${p.color}"></span>` +
		`<span class="name">${p.file}</span><span class="hint">${p.label}</span>`;
	li.addEventListener('click', () => selectPreset(p.id));
	fileList.appendChild(li);
}

canvas.addEventListener('click', () => {
	selectPreset((state.presetIndex + 1) % PRESETS.length);
});

window.addEventListener('keydown', (e) => {
	if (editor.view.hasFocus) return;
	if (e.key === ' ') {
		e.preventDefault();
		setPaused(!state.paused);
	} else if (e.key === 's' || e.key === 'S') {
		screenshot();
	} else if (e.key === 'Escape') {
		hideDiagnostic();
	} else if (/^[1-9]$/.test(e.key)) {
		const idx = parseInt(e.key, 10) - 1;
		if (idx >= 0 && idx < PRESETS.length) selectPreset(idx);
	}
});

// 全局 Cmd/Ctrl+S（编辑器未聚焦时也生效）
window.addEventListener('keydown', (e) => {
	if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's') {
		e.preventDefault();
		compileAllShaders();
	}
});

// 拖拽载入
installDnd({ overlay: $('drop-overlay'), onFiles: handleDroppedFiles });

// 调试钩子：暴露内部状态与渲染函数，供控制台 / 自动化脚本注入 playClock 截图
window.__viz = { state, audio, renderFrame, compileAllShaders, selectPreset };

// ============================================================
// 启动
// ============================================================

(async function main() {
	try {
		await loadAllShaderFiles();
		selectPreset(state.presetIndex);
		compileAllShaders();
		tick();
	} catch (err) {
		showDiagnostic(toDiagnostic(err, '启动'));
	}
})();
