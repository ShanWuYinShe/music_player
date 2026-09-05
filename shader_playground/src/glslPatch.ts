/**
 * GLSL ES 1.00 → WebGL2 (GLSL ES 3.00) 最小兼容补丁。
 *
 * 源文件直接来自 music_app/entry/src/main/cpp/shaders/（与手机端 CMake 打包
 * 的是同一份磁盘文件），本模块只做三件事：
 *   1. 注入 `#version 300 es` 头：精度、uniform/varying 与 out 声明；
 *   2. 把工具已统一声明的东西从源码里"置空"（保留行数！）；
 *   3. 词汇替换 texture2D→texture、attribute→in、gl_FragColor→fragColor。
 *
 * 公共库注入：场景共享的函数库 common.glsl 由调用方读盘后传入，同一份文本
 * 走同一套置空/替换管线后，插到"注入头之后、场景源之前"。场景源不得重复
 * 定义 common.glsl 里的函数。端侧 gen_shader_header.py 是同一套规则的另一
 * 份实现，两边注入的内容与行数必须逐字节一致。
 *
 * 行号对齐是硬性约束：所有 strip 都以空行代替删除，因此
 *   编译器报错行号 − (注入头行数 + common 行数) = 场景源文件行号；
 * 报错行号落在 common 区间内时，换算为 common.glsl 自身行号
 * （见 mapFragErrorLine），错误浮层两种都能精确定位。
 */
import { ShaderError } from './errors';
import { COMMON_FILE } from './presets';

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
	'uniform vec2 uTilt;\n' +
	'uniform float uTransition;\n' +
	'uniform sampler2D uPrev;\n' +
	'in vec2 vUV;\n' +
	'out vec4 fragColor;\n';

// 必须恰好是 VERT_HEADER_LINES(4) 行：换行由 \n 给出，源码排版不得拆行
const VERT_HEADER = `${VERSION_DIRECTIVE}precision highp float;\nin vec2 aPos;\nout vec2 vUV;\n`;

const BLIT_HEADER =
	VERSION_DIRECTIVE +
	'precision highp float;\n' +
	'in vec2 vUV;\n' +
	'uniform sampler2D uTex;\n' +
	'out vec4 fragColor;\n';

/** 注入头的行数；编译器行号 − 该值（frag 还要 − common 行数）= 源文件行号 */
export const FRAG_HEADER_LINES = 13;
export const VERT_HEADER_LINES = 4;
export const BLIT_HEADER_LINES = 5;

const FRAG_UNIFORM_NAMES = [
	'uT',
	'uSeed',
	'uRes',
	'uBeat',
	'uBass',
	'uTreble',
	'uTilt',
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

function replaceCommonWords(s: string): string {
	return s.replace(/\btexture2D[ \t]*\(/g, 'texture(');
}

/**
 * fragment 源码体（场景或 common.glsl）的统一变换：
 * 置空注入头已声明的行 + 词汇替换。所有置空都保留行数。
 */
function transformFragBody(src: string, label: string): string {
	let s = src;
	s = s.replace(VERSION_RE, '');
	s = s.replace(PRECISION_RE, '');
	s = s.replace(FRAG_UNIFORM_RE, '');
	// fragment 的 varying 是输入，已由工具头声明，整行置空
	s = s.replace(VARYING_RE, '');
	s = replaceCommonWords(s);
	s = s.replace(/\battribute[ \t]+/g, 'in ');
	s = s.replace(/\bgl_FragColor\b/g, 'fragColor');
	assertNoVersionLeft(s, label);
	return s;
}

/** 文本行数（以末尾补 \n 后的换行符数计；注入拼接时同样会补 \n，两者一致） */
export function countLines(s: string): number {
	const norm = s.endsWith('\n') ? s : `${s}\n`;
	return norm.split('\n').length - 1;
}

/**
 * frag 注入区的总行数：注入头 + common.glsl（有的话）。
 * 编译器报错行号减去它就是场景源文件行号（见 mapFragErrorLine）。
 */
export function fragInjectedLines(common?: string): number {
	return FRAG_HEADER_LINES + (common === undefined ? 0 : countLines(common));
}

export interface MappedLine {
	line: number;
	/** 设置时表示报错落在公共库里（值为 common.glsl 文件名），否则在场景源 */
	file?: string;
}

/**
 * 把编译器报错行号换算回源文件行号。
 * patched 布局：[注入头 FRAG_HEADER_LINES 行][common N 行][场景源 …]。
 */
export function mapFragErrorLine(patchedLine: number, common?: string): MappedLine {
	const commonLines = common === undefined ? 0 : countLines(common);
	if (
		commonLines > 0 &&
		patchedLine > FRAG_HEADER_LINES &&
		patchedLine <= FRAG_HEADER_LINES + commonLines
	) {
		return { line: patchedLine - FRAG_HEADER_LINES, file: COMMON_FILE };
	}
	return { line: patchedLine - FRAG_HEADER_LINES - commonLines };
}

/**
 * @param src    场景 fragment 源（GLSL ES 1.00）
 * @param label  错误标题用的文件名
 * @param common 公共库 common.glsl 源文本；传入后注入到头与场景源之间，
 *               场景源不得重复定义其中的函数
 */
export function patchFragForWebGL2(src: unknown, label = 'fragment', common?: string): string {
	const body = transformFragBody(requireString(src, label), label);
	if (common === undefined) return FRAG_HEADER + body;
	const lib = transformFragBody(requireString(common, COMMON_FILE), COMMON_FILE);
	const libNorm = lib.endsWith('\n') ? lib : `${lib}\n`;
	return FRAG_HEADER + libNorm + body;
}

export function patchVertForWebGL2(src: unknown, label = 'vertex'): string {
	let s = requireString(src, label);
	s = s.replace(VERSION_RE, '');
	s = s.replace(PRECISION_RE, '');
	// 源文件 vertex 头里只有 `attribute aPos` 与 `varying vUV`，由工具头统一声明
	s = s.replace(APOS_RE, '');
	s = s.replace(VARYING_RE, '');
	s = replaceCommonWords(s);
	assertNoVersionLeft(s, label);
	return VERT_HEADER + s;
}

export function patchBlitForWebGL2(src: unknown, label = 'blit.frag'): string {
	let s = requireString(src, label);
	s = s.replace(VERSION_RE, '');
	s = s.replace(PRECISION_RE, '');
	s = s.replace(BLIT_UNIFORM_RE, '');
	s = s.replace(VARYING_RE, '');
	s = replaceCommonWords(s);
	s = s.replace(/\battribute[ \t]+/g, 'in ');
	s = s.replace(/\bgl_FragColor\b/g, 'fragColor');
	assertNoVersionLeft(s, label);
	return BLIT_HEADER + s;
}
