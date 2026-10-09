import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, test } from 'vitest';
import { PRESETS } from '../src/presets';

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

function readRepoFile(path: string): string {
	return readFileSync(resolve(REPO_ROOT, path), 'utf8');
}

function capture(source: string, pattern: RegExp, label: string): string {
	const match = source.match(pattern);
	if (match === null || match[1] === undefined) {
		throw new Error(`无法从 ${label} 解析场景配置`);
	}
	return match[1];
}

function quotedStrings(source: string): string[] {
	return Array.from(source.matchAll(/["']([^"']+)["']/g), (match) => match[1] ?? '');
}

describe('shader 管线跨端配置一致性', () => {
	test('playground、CMake 与生成器使用同一场景顺序', () => {
		const expected = PRESETS.map((preset) => preset.file);
		const cmake = readRepoFile('music_app/entry/src/main/cpp/CMakeLists.txt');
		const cmakeScenes = capture(cmake, /set\(SHADER_SCENES\s+"([^"]+)"\)/, 'CMakeLists.txt').split(
			',',
		);
		const generator = readRepoFile('music_app/entry/src/main/cpp/tools/gen_shader_header.py');
		const generatorScenes = quotedStrings(
			capture(generator, /DEFAULT_SCENE_FILES\s*=\s*\[([^\]]+)\]/, 'gen_shader_header.py'),
		);

		expect(cmakeScenes).toEqual(expected);
		expect(generatorScenes).toEqual(expected);
		for (const scene of expected) {
			expect(existsSync(resolve(REPO_ROOT, 'music_app/entry/src/main/cpp/shaders', scene))).toBe(
				true,
			);
		}
	});

	test('ArkTS 名称、数量与 playground preset 对齐', () => {
		const expectedLabels = PRESETS.map((preset) => preset.label);
		const core = readRepoFile('music_app/entry/src/main/ets/common/VisualizerCore.ets');
		const names = quotedStrings(
			capture(
				core,
				/export const VIZ_PRESET_NAMES: string\[\] = \[([\s\S]*?)\];/,
				'VisualizerCore.ets',
			),
		);
		const view = readRepoFile('music_app/entry/src/main/ets/components/VisualizerView.ets');

		expect(names).toEqual(expectedLabels);
		expect(core).toContain('export const PRESET_COUNT = VIZ_PRESET_NAMES.length;');
		expect(view).not.toContain('export const PRESET_COUNT');
		// id 从 0 起连续（preset 轮换与 shader 槽位索引依赖它）
		expect(PRESETS.map((preset) => preset.id)).toEqual(PRESETS.map((_, i) => i));
		// 场景级帧间隔数组与场景清单同长（VisualizerView 按 presetLock 索引）
		const frameIntervals = capture(
			core,
			/export const VIZ_FRAME_INTERVAL_MS: number\[\] = \[([\s\S]*?)\];/,
			'VisualizerCore.ets',
		)
			.split(',')
			.map((v) => Number.parseFloat(v.trim()));
		expect(frameIntervals).toHaveLength(PRESETS.length);
		for (const v of frameIntervals) {
			expect(Number.isFinite(v) && v >= 25 && v <= 50).toBe(true);
		}
	});

	test('每场景内部渲染比例与端侧 kPresetScale 逐项对齐', () => {
		const cpp = readRepoFile('music_app/entry/src/main/cpp/visualizer.cpp');
		const scaleMatch = cpp.match(/kPresetScale\[kVizPresetCount\]\s*=\s*\{([^}]+)\}/);
		expect(scaleMatch).not.toBeNull();
		const cppScales = (scaleMatch?.[1] ?? '')
			.split(',')
			.map((s) => Number.parseFloat(s.trim().replace(/f$/, '')));
		expect(cppScales).toHaveLength(PRESETS.length);
		for (let i = 0; i < PRESETS.length; i++) {
			expect(cppScales[i]).toBeCloseTo(PRESETS[i]?.renderScale ?? NaN, 5);
		}
	});

	test('pan 状态预通道三端常量一致（槽位 / 纹理尺寸）', () => {
		const cpp = readRepoFile('music_app/entry/src/main/cpp/visualizer.cpp');
		const pan = readShader('pan.frag');
		const renderer = readRepoFile('shader_playground/src/renderer.ts');

		// 端侧 pan 槽位 = presets.ts 里 statePass 的场景索引
		const panSlot = Number((cpp.match(/kVizPresetPan\s*=\s*(\d+)/) ?? [])[1] ?? NaN);
		const statePassIdx = PRESETS.findIndex((preset) => preset.statePass === true);
		expect(statePassIdx).toBeGreaterThanOrEqual(0);
		expect(panSlot).toBe(statePassIdx);

		// 状态纹理尺寸 = pan.frag 的 DROPLET_COUNT × PAN_STATE_ROWS，三处一致
		const dropCount = Number((pan.match(/DROPLET_COUNT\s*=\s*(\d+)/) ?? [])[1] ?? NaN);
		const stateRows = Number((pan.match(/PAN_STATE_ROWS\s*=\s*(\d+)/) ?? [])[1] ?? NaN);
		const cppW = Number((cpp.match(/kPanStateTexW\s*=\s*(\d+)/) ?? [])[1] ?? NaN);
		const cppH = Number((cpp.match(/kPanStateTexH\s*=\s*(\d+)/) ?? [])[1] ?? NaN);
		const tsW = Number((renderer.match(/PAN_STATE_W\s*=\s*(\d+)/) ?? [])[1] ?? NaN);
		const tsH = Number((renderer.match(/PAN_STATE_H\s*=\s*(\d+)/) ?? [])[1] ?? NaN);
		expect(dropCount).toBe(cppW);
		expect(cppW).toBe(tsW);
		expect(stateRows).toBe(cppH);
		expect(cppH).toBe(tsH);
	});

	test('体感 uniform（uTilt/uSpin/uKick）两端注入头一致', () => {
		const generator = readRepoFile('music_app/entry/src/main/cpp/tools/gen_shader_header.py');
		const patch = readRepoFile('shader_playground/src/glslPatch.ts');
		const genUniforms = quotedStrings(
			capture(generator, /FRAG_UNIFORMS\s*=\s*\[([^\]]+)\]/, 'gen_shader_header.py'),
		);
		const tsUniforms = quotedStrings(
			capture(patch, /FRAG_UNIFORM_NAMES\s*=\s*\[([^\]]+)\]/, 'glslPatch.ts'),
		);
		expect(tsUniforms).toEqual(genUniforms);
		expect(genUniforms).toContain('uTilt');
		expect(genUniforms).toContain('uSpin');
		expect(genUniforms).toContain('uKick');
		// 注入头行数两端一致（编译报错行号换算依赖它：头 15 + common 行数）
		const tsHeaderLines = Number((patch.match(/FRAG_HEADER_LINES\s*=\s*(\d+)/) ?? [])[1] ?? NaN);
		expect(tsHeaderLines).toBe(15);
		expect(generator).toContain('frag_injected = 15 +');
		// NAPI 与 ArkTS 传参对齐（renderFrame 11 参：…tiltX, tiltY, spin, kick；
		// 2019467 死代码清理由 12 减为 11，勿回调）
		const view = readRepoFile('music_app/entry/src/main/ets/components/VisualizerView.ets');
		expect(view).toContain('this.tiltX, this.tiltY, this.spin, this.kick');
		const napi = readRepoFile('music_app/entry/src/main/cpp/napi_init.cpp');
		expect(napi).toContain('size_t argc = 11;');
	});
});

/** 读 shaders/ 目录下的场景源（与 regression.test.ts 同约定） */
function readShader(name: string): string {
	return readFileSync(resolve(REPO_ROOT, 'music_app/entry/src/main/cpp/shaders', name), 'utf8');
}
