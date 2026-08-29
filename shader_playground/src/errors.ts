/**
 * 统一诊断格式化：任何一路错误（GLSL 编译对象 / JS Error / 未知值）进入这里，
 * 都必须产出人类可读的 title + log。历史上任何非 GLSL 异常走到旧版的
 * `err.log` 直接取值会显示成字面量 "undefined"，这里从根上杜绝：
 * 每个分支都以确定的字符串收尾，绝不输出 undefined。
 */

export interface Diagnostic {
	title: string;
	log: string;
}

const kindNames: Record<string, string> = {
	compile: '编译错误',
	link: '链接错误',
	source: '源码错误',
};

/**
 * 渲染器/补丁层抛出的结构化着色器错误。
 * `line` 是换算回源文件的行号（glslPatch 的置空式 strip 保证了 patched 行号
 * 与源文件只差一个固定头长度，见 glslPatch.ts）。
 */
export class ShaderError extends Error {
	readonly kind: 'compile' | 'link' | 'source';
	readonly label: string;
	readonly detail: string;
	readonly sourceLine: number | null;
	/** 行号落在公共库时给出文件名（如 common.glsl）；null 表示在 label 源文件里 */
	readonly sourceFile: string | null;

	constructor(
		kind: 'compile' | 'link' | 'source',
		label: string,
		detail: string,
		sourceLine?: number,
		sourceFile?: string,
	) {
		super(detail);
		this.name = 'ShaderError';
		this.kind = kind;
		this.label = label;
		this.detail = detail;
		this.sourceLine = sourceLine ?? null;
		this.sourceFile = sourceFile ?? null;
	}
}

function describeValue(v: unknown): string {
	if (typeof v === 'string') return v;
	if (typeof v === 'number' || typeof v === 'boolean' || typeof v === 'bigint') return String(v);
	if (v === null) return 'null';
	if (v === undefined) return '（无错误信息）';
	try {
		const json = JSON.stringify(v, null, 2);
		if (typeof json === 'string' && json.trim()) return json;
	} catch {
		// 循环引用等 stringify 失败，落到 String()
	}
	const s = String(v);
	return s.trim() ? s : '（无错误信息）';
}

export function toDiagnostic(err: unknown, fallbackTitle: string): Diagnostic {
	if (err instanceof ShaderError) {
		const kind = kindNames[err.kind] ?? '错误';
		const title = err.label ? `${kind} · ${err.label}` : `${kind} · ${fallbackTitle}`;
		let log = err.detail || '（无日志）';
		if (err.sourceLine !== null) {
			log += `\n\n（${err.sourceFile ?? '源文件'}第 ${err.sourceLine} 行附近）`;
		}
		return { title, log };
	}
	if (err instanceof Error) {
		return {
			title: `内部错误 · ${fallbackTitle}`,
			log: `${err.name}: ${err.message || '（无错误信息）'}`,
		};
	}
	if (typeof err === 'string' && err.trim()) {
		return { title: `错误 · ${fallbackTitle}`, log: err };
	}
	return { title: `错误 · ${fallbackTitle}`, log: describeValue(err) };
}
