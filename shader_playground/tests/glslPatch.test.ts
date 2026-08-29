import { describe, expect, test } from 'bun:test';
import { ShaderError } from '../src/errors';
import {
	BLIT_HEADER_LINES,
	FRAG_HEADER_LINES,
	hasEntryPoint,
	patchBlitForWebGL2,
	patchFragForWebGL2,
	patchVertForWebGL2,
	VERT_HEADER_LINES,
} from '../src/glslPatch';

const FRAG_SRC = [
	'#version 100',
	'precision highp float;',
	'varying vec2 vUV;',
	'uniform float uT;',
	'uniform float uSeed;',
	'uniform vec2 uRes;',
	'uniform float uBeat;',
	'uniform float uBass;',
	'uniform float uTreble;',
	'uniform float uTransition;',
	'uniform sampler2D uPrev;',
	'void main() {',
	'  vec3 c = texture2D(uPrev, vUV).rgb + vec3(uT, uSeed, uBeat);',
	'  gl_FragColor = vec4(c * uBass * uTreble * uTransition * uRes.x, 1.0);',
	'}',
].join('\n');

/** 取注入头之后的源码体（头部声明来自工具注入，不应参与"已删除"断言） */
function bodyAfter(out: string, lastHeaderLine: string): string {
	return out.slice(out.lastIndexOf(lastHeaderLine) + lastHeaderLine.length);
}

describe('patchFragForWebGL2', () => {
	test('注入 300 es 头并完成词汇替换', () => {
		const out = patchFragForWebGL2(FRAG_SRC);
		expect(out.startsWith('#version 300 es\n')).toBe(true);
		expect(out).toContain('texture(uPrev, vUV)');
		expect(out).toContain('fragColor');
		expect(out).not.toContain('texture2D');
		expect(out).not.toContain('gl_FragColor');
	});

	test('行号对齐：patched 行 = 源行 + 头行数（strip 一律置空不删行）', () => {
		const out = patchFragForWebGL2(FRAG_SRC);
		const lines = out.split('\n');
		// 源文件第 i 行（0 基）出现在 patched 的 FRAG_HEADER_LINES + i 行
		expect(lines[FRAG_HEADER_LINES + 0]).toBe('');
		expect(lines[FRAG_HEADER_LINES + 11]).toBe('void main() {');
		expect(lines[FRAG_HEADER_LINES + 13]).toContain('fragColor');
		expect(lines).toHaveLength(FRAG_HEADER_LINES + FRAG_SRC.split('\n').length);
	});

	test('工具头声明的 uniform 已置空，自定义 uniform 保留', () => {
		const body = bodyAfter(patchFragForWebGL2(FRAG_SRC), 'out vec4 fragColor;\n');
		expect(body).not.toContain('uniform float uT;');
		const custom = FRAG_SRC.replace(
			'uniform sampler2D uPrev;',
			'uniform sampler2D uPrev;\nuniform float uCustom;',
		);
		expect(patchFragForWebGL2(custom)).toContain('uniform float uCustom;');
	});

	test('uT/uTreble/uTransition 等前缀重叠的 uniform 都能置空', () => {
		const body = bodyAfter(patchFragForWebGL2(FRAG_SRC), 'out vec4 fragColor;\n');
		for (const name of ['uT', 'uTreble', 'uTransition', 'uPrev', 'uSeed']) {
			expect(body).not.toContain(`uniform float ${name};`);
		}
	});

	test('非字符串输入抛 ShaderError.source（不再显示 undefined）', () => {
		try {
			patchFragForWebGL2(undefined);
			expect.unreachable();
		} catch (err) {
			expect(err).toBeInstanceOf(ShaderError);
			expect((err as ShaderError).kind).toBe('source');
		}
	});

	test('中间行的 #version 给出可读错误', () => {
		const bad = '#version 100\nprecision highp float;\n\n#version 100\n';
		try {
			patchFragForWebGL2(bad);
			expect.unreachable();
		} catch (err) {
			expect(err).toBeInstanceOf(ShaderError);
			expect((err as ShaderError).detail).toContain('#version');
		}
	});
});

describe('patchVertForWebGL2 / patchBlitForWebGL2', () => {
	const VERT_SRC = [
		'#version 100',
		'attribute vec2 aPos;',
		'varying vec2 vUV;',
		'void main() {',
		'  vUV = aPos * 0.5 + 0.5;',
		'  gl_Position = vec4(aPos, 0.0, 1.0);',
		'}',
	].join('\n');

	const BLIT_SRC = [
		'#version 100',
		'precision highp float;',
		'varying vec2 vUV;',
		'uniform sampler2D uTex;',
		'void main() { gl_FragColor = texture2D(uTex, vUV); }',
	].join('\n');

	test('vert：attribute/varying 置空，行号对齐', () => {
		const out = patchVertForWebGL2(VERT_SRC);
		expect(out.startsWith('#version 300 es\n')).toBe(true);
		const lines = out.split('\n');
		expect(lines).toHaveLength(VERT_HEADER_LINES + VERT_SRC.split('\n').length);
		expect(lines[VERT_HEADER_LINES + 3]).toBe('void main() {');
		expect(out).not.toContain('attribute');
		expect(out).not.toContain('varying');
	});

	test('blit：uTex 置空、texture 替换、行号对齐', () => {
		const out = patchBlitForWebGL2(BLIT_SRC);
		expect(out.startsWith('#version 300 es\n')).toBe(true);
		const lines = out.split('\n');
		expect(lines).toHaveLength(BLIT_HEADER_LINES + BLIT_SRC.split('\n').length);
		expect(out).toContain('texture(uTex, vUV)');
		expect(bodyAfter(out, 'out vec4 fragColor;\n')).not.toContain('uniform sampler2D uTex;');
		expect(bodyAfter(out, 'out vec4 fragColor;\n')).not.toContain('texture2D');
	});
});

describe('hasEntryPoint 草稿检测', () => {
	test('含 void main 判为可编译', () => {
		expect(hasEntryPoint('void main() {}')).toBe(true);
		expect(hasEntryPoint('void  main ( ) {}')).toBe(true);
		expect(hasEntryPoint(FRAG_SRC)).toBe(true);
	});

	test('空串 / 注释 / 非字符串判为草稿', () => {
		expect(hasEntryPoint('')).toBe(false);
		expect(hasEntryPoint('   \n\t')).toBe(false);
		expect(hasEntryPoint('// 只写了注释')).toBe(false);
		expect(hasEntryPoint('void mainLoop() {}')).toBe(false);
		expect(hasEntryPoint(undefined)).toBe(false);
		expect(hasEntryPoint(null)).toBe(false);
	});
});
