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
	if (match === null) {
		throw new Error(`无法从 ${label} 解析场景配置`);
	}
	return match[1];
}

function quotedStrings(source: string): string[] {
	return Array.from(source.matchAll(/["']([^"']+)["']/g), (match) => match[1]);
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
		expect(PRESETS.map((preset) => preset.id)).toEqual([0, 1, 2, 3]);
	});
});
