/**
 * GLSL ES 1.00 → WebGL2 (GLSL ES 3.00) 最小兼容补丁。
 *
 * 源文件直接来自 music_app/entry/src/main/cpp/shaders/（与手机端 CMake 打包
 * 的是同一份磁盘文件），本模块只做三件事：
 *   1. 注入 `#version 300 es` 头：精度、uniform/varying 与 out 声明；
 *   2. 把工具已统一声明的东西从源码里"置空"（保留行数！）；
 *   3. 词汇替换 texture2D→texture、attribute→in、gl_FragColor→fragColor。
 *
 * 行号对齐是硬性约束：所有 strip 都以空行代替删除，因此编译器报错的行号
 * 减去注入头行数就是源文件行号，错误浮层可以精确定位。
 */
import { ShaderError } from './errors';

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
	VERSION_DIRECTIVE + 'precision highp float;\n' + 'in vec2 aPos;\n' + 'out vec2 vUV;\n';

const BLIT_HEADER =
	VERSION_DIRECTIVE +
	'precision highp float;\n' +
	'in vec2 vUV;\n' +
	'uniform sampler2D uTex;\n' +
	'out vec4 fragColor;\n';

/** 注入头的行数；编译器行号 − 该值 = 源文件行号 */
export const FRAG_HEADER_LINES = 12;
export const VERT_HEADER_LINES = 4;
export const BLIT_HEADER_LINES = 5;

const FRAG_UNIFORM_NAMES = [
	'uT',
	'uSeed',
	'uRes',
	'uBeat',
	'uBass',
	'uTreble',
	'uTransition',
	'uPrev',
];
const BLIT_UNIFORM_NAMES = ['uTex'];

function escapeReg(s: string): string {
	return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * 构造"整行置空"的正则。注意只允许空格/缩进匹配（[ \t]），不允许跨行的 \s*，
 * 否则置换会吞掉相邻空行、破坏行号对齐。
 */
function buildUniformBlankPattern(names: string[]): RegExp {
	const alt = names.map(escapeReg).join('|');
	return new RegExp(`^[ \\t]*uniform[ \\t]+\\w+[ \\t]+(?:${alt})[ \\t]*;[ \\t]*`, 'gm');
}

const FRAG_UNIFORM_RE = buildUniformBlankPattern(FRAG_UNIFORM_NAMES);
const BLIT_UNIFORM_RE = buildUniformBlankPattern(BLIT_UNIFORM_NAMES);

// 通用整行置空模式：#version / precision / varying / attribute（输入侧）
const VERSION_RE = /^[ \t]*#version[^\n]*/;
const PRECISION_RE = /^[ \t]*precision[ \t]+\w+[ \t]+\w+[ \t]*;[ \t]*/gm;
const VARYING_RE = /^[ \t]*varying[ \t]+[^;\n]+;[ \t]*/gm;
const APOS_RE = /^[ \t]*(?:attribute|in)[ \t]+vec2[ \t]+aPos[ \t]*;[ \t]*/gm;
const MAIN_RE = /\bvoid[ \t]+main[ \t]*\(/;

/**
 * 草稿检测：编辑中被清空 / 还没写到 main() 的源码不算错误，
 * 跳过编译并保留上一版 program（清空后报链接错误极不合理）。
 */
export function hasEntryPoint(src: unknown): boolean {
	return typeof src === 'string' && MAIN_RE.test(src);
}

function requireString(src: unknown, what: string): string {
	if (typeof src !== 'string') {
		throw new ShaderError(
			'source',
			what,
			`源码不是文本（得到 ${src === null ? 'null' : typeof src}），请重新载入源文件`,
		);
	}
	return src;
}

/** 把源码开头残留的 #version 暴露成可读错误（正常应已被置空） */
function assertNoVersionLeft(s: string, label: string): void {
	if (/(^|\n)[ \t]*#version/.test(s)) {
		throw new ShaderError(
			'source',
			label,
			'源文件中 #version 只能出现在第一行（或不要写，工具会自动注入）',
		);
	}
}

function replaceCommon(s: string): string {
	return s.replace(/\btexture2D[ \t]*\(/g, 'texture(');
}

export function patchFragForWebGL2(src: unknown, label = 'fragment'): string {
	let s = requireString(src, label);
	s = s.replace(VERSION_RE, '');
	s = s.replace(PRECISION_RE, '');
	s = s.replace(FRAG_UNIFORM_RE, '');
	// fragment 的 varying 是输入，已由工具头声明，整行置空
	s = s.replace(VARYING_RE, '');
	s = replaceCommon(s);
	s = s.replace(/\battribute[ \t]+/g, 'in ');
	s = s.replace(/\bgl_FragColor\b/g, 'fragColor');
	assertNoVersionLeft(s, label);
	return FRAG_HEADER + s;
}

export function patchVertForWebGL2(src: unknown, label = 'vertex'): string {
	let s = requireString(src, label);
	s = s.replace(VERSION_RE, '');
	s = s.replace(PRECISION_RE, '');
	// 源文件 vertex 头里只有 `attribute aPos` 与 `varying vUV`，由工具头统一声明
	s = s.replace(APOS_RE, '');
	s = s.replace(VARYING_RE, '');
	s = replaceCommon(s);
	assertNoVersionLeft(s, label);
	return VERT_HEADER + s;
}

export function patchBlitForWebGL2(src: unknown, label = 'blit.frag'): string {
	let s = requireString(src, label);
	s = s.replace(VERSION_RE, '');
	s = s.replace(PRECISION_RE, '');
	s = s.replace(BLIT_UNIFORM_RE, '');
	s = s.replace(VARYING_RE, '');
	s = replaceCommon(s);
	s = s.replace(/\battribute[ \t]+/g, 'in ');
	s = s.replace(/\bgl_FragColor\b/g, 'fragColor');
	assertNoVersionLeft(s, label);
	return BLIT_HEADER + s;
}
