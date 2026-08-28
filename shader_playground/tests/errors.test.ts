import { describe, expect, test } from 'bun:test';
import { ShaderError, toDiagnostic } from '../src/errors';

describe('toDiagnostic：任何错误输入都不产生 "undefined"', () => {
	test('ShaderError（编译错误）带源文件行号提示', () => {
		const d = toDiagnostic(
			new ShaderError('compile', 'fractal.frag', "ERROR: 0:13: 'x' : undeclared", 13),
			'f',
		);
		expect(d.title).toBe('编译错误 · fractal.frag');
		expect(d.log).toContain('源文件第 13 行');
		expect(d.log).not.toContain('undefined');
	});

	test('ShaderError（链接错误）无行号提示', () => {
		const d = toDiagnostic(new ShaderError('link', 'blit', 'missing main'), 'f');
		expect(d.title).toBe('链接错误 · blit');
		expect(d.log).toContain('missing main');
	});

	test('JS Error → 内部错误 + name: message', () => {
		const d = toDiagnostic(
			new TypeError("Cannot read properties of undefined (reading 'replace')"),
			'fractal',
		);
		expect(d.title).toBe('内部错误 · fractal');
		expect(d.log).toBe("TypeError: Cannot read properties of undefined (reading 'replace')");
		expect(d.log).not.toBe('undefined');
	});

	test('字符串错误', () => {
		const d = toDiagnostic('磁盘文件不可读', 'f');
		expect(d.title).toBe('错误 · f');
		expect(d.log).toBe('磁盘文件不可读');
	});

	test('任意对象 → JSON 序列化', () => {
		const d = toDiagnostic({ code: 7, reason: 'bad source' }, 'f');
		expect(d.log).toContain('bad source');
		expect(d.log).not.toContain('undefined');
	});

	test('null / undefined / 空对象 / 循环引用都有兜底文案', () => {
		for (const v of [null, undefined, {}, Symbol('x')]) {
			const d = toDiagnostic(v, 'f');
			expect(d.title).not.toContain('undefined');
			expect(d.log).not.toBe('undefined');
			expect(d.log.trim().length).toBeGreaterThan(0);
		}
		const cyc: Record<string, unknown> = {};
		cyc.self = cyc;
		const d = toDiagnostic(cyc, 'f');
		expect(d.log.trim().length).toBeGreaterThan(0);
	});

	test('detail 为空的 ShaderError 显示兜底日志', () => {
		const err = new ShaderError('source', 'pan.frag', '');
		const d = toDiagnostic(err, 'pan');
		expect(d.log.trim()).toBe('（无日志）');
	});
});
