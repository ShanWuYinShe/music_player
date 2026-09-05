/**
 * WebGL2 渲染管线：与手机端 cpp/visualizer.cpp 一致的
 * 全屏三角形 + 反馈 FBO ping-pong + 内部降采样 + blit 上屏。
 * 差异仅在 GLSL ES 1.00 → 3.00 的补丁（见 glslPatch.ts）。
 * pan 状态预通道同样对齐端侧：每帧先以 20×4 小视口（uStateMode=1）把
 * 每滴水珠状态写进 RGBA16F 纹理，主 pass（uStateMode=2）texelFetch 取用；
 * WebGL 上下文缺 EXT_color_buffer_float 时，按端侧同一手法在 #version 行
 * 后插 #define PAN_NO_STATE_TEX 1 编译逐像素回退变体。
 */
import { type Diagnostic, ShaderError, toDiagnostic } from './errors';
import {
	BLIT_HEADER_LINES,
	hasEntryPoint,
	mapFragErrorLine,
	patchBlitForWebGL2,
	patchFragForWebGL2,
	patchVertForWebGL2,
	VERT_HEADER_LINES,
} from './glslPatch';
import { BLIT_FILE, COMMON_FILE, PRESETS, VERT_FILE } from './presets';

export interface RenderParams {
	t: number;
	seed: number;
	beat: number;
	bass: number;
	treble: number;
	transition: number;
	/** 设备倾斜 [-1,1]（手机端 ORIENTATION 姿态角；playground 由指针位置映射） */
	tiltX: number;
	tiltY: number;
	/** 内部分辨率比例（对应手机端 kPresetScale） */
	renderScale: number;
}

interface SceneUniforms {
	t: WebGLUniformLocation | null;
	seed: WebGLUniformLocation | null;
	res: WebGLUniformLocation | null;
	beat: WebGLUniformLocation | null;
	bass: WebGLUniformLocation | null;
	treble: WebGLUniformLocation | null;
	transition: WebGLUniformLocation | null;
	tilt: WebGLUniformLocation | null;
	prev: WebGLUniformLocation | null;
	/** pan 专用：uStateMode / uState（其他场景无此 uniform，恒 null） */
	stateMode: WebGLUniformLocation | null;
	state: WebGLUniformLocation | null;
}

/** pan 状态纹理尺寸：宽 = DROPLET_COUNT(20)、高 = PAN_STATE_ROWS(4)，
 * 与 pan.frag、visualizer.cpp 的常量一一对应（改那边必须同步这里） */
const PAN_STATE_W = 20;
const PAN_STATE_H = 4;

/** 端侧 WithPanStateDisabled 的同构实现：#version 必须保持首行 */
function withPanStateDisabled(patchedSrc: string): string {
	const nl = patchedSrc.indexOf('\n');
	if (nl < 0) return patchedSrc;
	return `${patchedSrc.slice(0, nl + 1)}#define PAN_NO_STATE_TEX 1\n${patchedSrc.slice(nl + 1)}`;
}

/** 编译器报错行号 → 源文件行号（可能落在公共库 common.glsl 里） */
type LineMapper = (patchedLine: number) => { line: number; file?: string };

/** 固定头行数的简单映射（vert / blit 无 common 注入） */
function offsetMapper(headerLines: number): LineMapper {
	return (patchedLine) => ({ line: patchedLine - headerLines });
}

function compileShader(
	gl: WebGL2RenderingContext,
	type: number,
	src: string,
	label: string,
	mapLine: LineMapper,
): WebGLShader {
	const sh = gl.createShader(type);
	if (!sh) throw new ShaderError('compile', label, 'createShader 返回空（上下文可能已丢失）');
	gl.shaderSource(sh, src);
	gl.compileShader(sh);
	if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
		const log = (gl.getShaderInfoLog(sh) || '（驱动未返回日志）').replace(/\0/g, '');
		const lineMatch = log.match(/ERROR:\s*\d+:(\d+)/);
		gl.deleteShader(sh);
		const mapped = lineMatch?.[1] ? mapLine(parseInt(lineMatch[1], 10)) : undefined;
		throw new ShaderError('compile', label, log.trim(), mapped?.line, mapped?.file);
	}
	return sh;
}

function linkProgram(
	gl: WebGL2RenderingContext,
	vs: WebGLShader,
	fs: WebGLShader,
	label: string,
): WebGLProgram {
	const p = gl.createProgram();
	if (!p) throw new ShaderError('link', label, 'createProgram 返回空（上下文可能已丢失）');
	gl.attachShader(p, vs);
	gl.attachShader(p, fs);
	gl.bindAttribLocation(p, 0, 'aPos');
	gl.linkProgram(p);
	if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
		const log = gl.getProgramInfoLog(p) || '（驱动未返回日志）';
		gl.deleteProgram(p);
		throw new ShaderError('link', label, log.trim());
	}
	return p;
}

function getSceneLocs(gl: WebGL2RenderingContext, p: WebGLProgram): SceneUniforms {
	return {
		t: gl.getUniformLocation(p, 'uT'),
		seed: gl.getUniformLocation(p, 'uSeed'),
		res: gl.getUniformLocation(p, 'uRes'),
		beat: gl.getUniformLocation(p, 'uBeat'),
		bass: gl.getUniformLocation(p, 'uBass'),
		treble: gl.getUniformLocation(p, 'uTreble'),
		transition: gl.getUniformLocation(p, 'uTransition'),
		tilt: gl.getUniformLocation(p, 'uTilt'),
		prev: gl.getUniformLocation(p, 'uPrev'),
		stateMode: gl.getUniformLocation(p, 'uStateMode'),
		state: gl.getUniformLocation(p, 'uState'),
	};
}

export class VizRenderer {
	readonly gl: WebGL2RenderingContext;
	private canvas: HTMLCanvasElement;
	private programs: (WebGLProgram | null)[] = PRESETS.map(() => null);
	private locs: (SceneUniforms | null)[] = PRESETS.map(() => null);
	private blitProgram: WebGLProgram | null = null;
	private blitLoc: WebGLUniformLocation | null = null;
	private vao: WebGLVertexArrayObject | null = null;
	private texs: (WebGLTexture | null)[] = [null, null];
	private fbos: (WebGLFramebuffer | null)[] = [null, null];
	private fboW = 0;
	private fboH = 0;
	private flip = 0;
	/** pan 状态预通道资源；stateTex 为 null 表示回退逐像素路径（无浮点 FBO） */
	private stateTex: WebGLTexture | null = null;
	private stateFbo: WebGLFramebuffer | null = null;

	constructor(canvas: HTMLCanvasElement) {
		this.canvas = canvas;
		const gl = canvas.getContext('webgl2', {
			alpha: false,
			antialias: false,
			preserveDrawingBuffer: true,
			premultipliedAlpha: false,
		});
		if (!gl) {
			throw new Error('WebGL2 不可用：请更换支持 WebGL2 的浏览器');
		}
		this.gl = gl;

		const kQuad = new Float32Array([-1, -1, 3, -1, -1, 3]);
		const vbo = gl.createBuffer();
		gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
		gl.bufferData(gl.ARRAY_BUFFER, kQuad, gl.STATIC_DRAW);
		this.vao = gl.createVertexArray();
		gl.bindVertexArray(this.vao);
		gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
		gl.enableVertexAttribArray(0);
		gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
		gl.bindVertexArray(null);

		// pan 状态预通道：RGBA16F 颜色缓冲需要 EXT_color_buffer_float（WebGL2
		// 核心不含）。不可用时 stateTex 保持 null，compileAll 会按编译期开关
		// 给 pan 编逐像素回退变体（与端侧 visualizer.cpp 同构）
		if (gl.getExtension('EXT_color_buffer_float')) {
			const tex = gl.createTexture();
			gl.bindTexture(gl.TEXTURE_2D, tex);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
			gl.texImage2D(
				gl.TEXTURE_2D,
				0,
				gl.RGBA16F,
				PAN_STATE_W,
				PAN_STATE_H,
				0,
				gl.RGBA,
				gl.HALF_FLOAT,
				null,
			);
			const fbo = gl.createFramebuffer();
			gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
			gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
			if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE) {
				this.stateTex = tex;
				this.stateFbo = fbo;
			} else {
				gl.deleteFramebuffer(fbo);
				gl.deleteTexture(tex);
			}
			gl.bindFramebuffer(gl.FRAMEBUFFER, null);
		}
	}

	/**
	 * 编译全部 program（blit + 4 场景）。任一失败：保留旧 program、返回诊断；
	 * 全部成功：替换并返回 null。草稿（无 main()）的场景文件跳过编译、
	 * 沿用旧 program，返回 skipDraft 标记供状态栏提示。
	 *
	 * 顶点 shader 只编译一次，供全部 program 复用（与 visualizer.cpp 一致）；
	 * 场景 fragment 注入 common.glsl 公共库（sources[COMMON_FILE]）。
	 */
	compileAll(sources: Record<string, string>): {
		diag: Diagnostic | null;
		skippedDrafts: string[];
	} {
		const gl = this.gl;
		const skippedDrafts: string[] = [];
		const common = sources[COMMON_FILE];
		if (typeof common !== 'string') {
			return {
				diag: toDiagnostic(
					new ShaderError('source', COMMON_FILE, `公共库 ${COMMON_FILE} 尚未载入`),
					'公共库',
				),
				skippedDrafts,
			};
		}

		// 顶点 shader 编译一次（attach 到多个 program，最后统一 deleteShader）
		let vs: WebGLShader | null = null;
		try {
			vs = compileShader(
				gl,
				gl.VERTEX_SHADER,
				patchVertForWebGL2(sources[VERT_FILE]),
				VERT_FILE,
				offsetMapper(VERT_HEADER_LINES),
			);
		} catch (err) {
			return { diag: toDiagnostic(err, '顶点管线'), skippedDrafts };
		}
		try {
			const blitSrc = patchBlitForWebGL2(sources[BLIT_FILE], BLIT_FILE);
			const fs = compileShader(
				gl,
				gl.FRAGMENT_SHADER,
				blitSrc,
				BLIT_FILE,
				offsetMapper(BLIT_HEADER_LINES),
			);
			const newBlit = linkProgram(gl, vs, fs, 'blit');
			gl.deleteShader(fs);
			if (this.blitProgram) gl.deleteProgram(this.blitProgram);
			this.blitProgram = newBlit;
			this.blitLoc = gl.getUniformLocation(newBlit, 'uTex');
		} catch (err) {
			gl.deleteShader(vs);
			return { diag: toDiagnostic(err, 'blit 管线'), skippedDrafts };
		}

		for (const preset of PRESETS) {
			const src = sources[preset.file];
			if (typeof src !== 'string') {
				gl.deleteShader(vs);
				return {
					diag: toDiagnostic(
						new ShaderError('source', preset.file, `源文件 ${preset.file} 尚未载入`),
						preset.label,
					),
					skippedDrafts,
				};
			}
			// 草稿（清空/尚未写到 main）不是错误：跳过，保留上一版画面
			if (!hasEntryPoint(src)) {
				skippedDrafts.push(preset.file);
				continue;
			}
			try {
				let fragSrc = patchFragForWebGL2(src, preset.file, common);
				// pan 在无浮点 FBO 的上下文里编译回退变体（在 #version 后插
				// 编译期开关，与端侧一致；回退变体的报错行号会比源文件 +1）
				if (preset.statePass && this.stateTex === null) {
					fragSrc = withPanStateDisabled(fragSrc);
				}
				const fs = compileShader(gl, gl.FRAGMENT_SHADER, fragSrc, preset.file, (line) =>
					mapFragErrorLine(line, common),
				);
				const p = linkProgram(gl, vs, fs, preset.name);
				gl.deleteShader(fs);
				if (this.programs[preset.id]) gl.deleteProgram(this.programs[preset.id] ?? null);
				this.programs[preset.id] = p;
				this.locs[preset.id] = getSceneLocs(gl, p);
			} catch (err) {
				gl.deleteShader(vs);
				return { diag: toDiagnostic(err, preset.label), skippedDrafts };
			}
		}
		gl.deleteShader(vs);
		return { diag: null, skippedDrafts };
	}

	get ready(): boolean {
		return this.blitProgram !== null && this.programs.some((p) => p !== null);
	}

	/** ping-pong 槽位访问（把 noUncheckedIndexedAccess 的 undefined 归一成 null） */
	private texAt(i: number): WebGLTexture | null {
		return this.texs[i] ?? null;
	}

	private fboAt(i: number): WebGLFramebuffer | null {
		return this.fbos[i] ?? null;
	}

	private ensureFboSize(w: number, h: number): void {
		w = Math.max(1, Math.floor(w));
		h = Math.max(1, Math.floor(h));
		const gl = this.gl;
		if (this.fboW === w && this.fboH === h && this.texAt(0)) return;
		const oldTexs = [this.texAt(0), this.texAt(1)];
		const oldFbos = [this.fboAt(0), this.fboAt(1)];
		const hadOld = oldTexs[0] !== null && this.fboW > 1 && this.fboH > 1;
		const texs: (WebGLTexture | null)[] = [gl.createTexture(), gl.createTexture()];
		const fbos: (WebGLFramebuffer | null)[] = [gl.createFramebuffer(), gl.createFramebuffer()];
		for (let i = 0; i < 2; i++) {
			gl.bindTexture(gl.TEXTURE_2D, texs[i] ?? null);
			gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
			gl.bindFramebuffer(gl.FRAMEBUFFER, fbos[i] ?? null);
			gl.framebufferTexture2D(
				gl.FRAMEBUFFER,
				gl.COLOR_ATTACHMENT0,
				gl.TEXTURE_2D,
				texs[i] ?? null,
				0,
			);
		}
		// 旧帧内容 blit 拷贝到新尺寸（线性重采样）——每场景 renderScale 不同，
		// 切风格触发重建时保住 uTransition 交叉淡化依赖的旧画面
		if (hadOld && this.blitProgram) {
			gl.bindVertexArray(this.vao);
			gl.useProgram(this.blitProgram);
			gl.viewport(0, 0, w, h);
			for (let i = 0; i < 2; i++) {
				gl.bindFramebuffer(gl.FRAMEBUFFER, fbos[i] ?? null);
				gl.activeTexture(gl.TEXTURE0);
				gl.bindTexture(gl.TEXTURE_2D, oldTexs[i] ?? null);
				gl.uniform1i(this.blitLoc, 0);
				gl.drawArrays(gl.TRIANGLES, 0, 3);
			}
			gl.bindVertexArray(null);
		}
		for (const t of oldTexs) {
			if (t) gl.deleteTexture(t);
		}
		for (const f of oldFbos) {
			if (f) gl.deleteFramebuffer(f);
		}
		gl.bindFramebuffer(gl.FRAMEBUFFER, null);
		this.texs = texs;
		this.fbos = fbos;
		this.fboW = w;
		this.fboH = h;
		this.flip = 0;
	}

	/** 渲染一帧（presetIndex 指定场景 program） */
	draw(presetIndex: number, p: RenderParams): void {
		if (!this.ready) return;
		const gl = this.gl;
		const dpr = window.devicePixelRatio || 1;
		const targetW = Math.max(1, Math.floor(this.canvas.clientWidth * dpr));
		const targetH = Math.max(1, Math.floor(this.canvas.clientHeight * dpr));
		if (this.canvas.width !== targetW || this.canvas.height !== targetH) {
			this.canvas.width = targetW;
			this.canvas.height = targetH;
		}
		const fboW = Math.max(1, Math.floor(targetW * p.renderScale));
		const fboH = Math.max(1, Math.floor(targetH * p.renderScale));
		this.ensureFboSize(fboW, fboH);

		// Pass S（仅 pan）：状态预通道——20×4 小视口、uStateMode=1，把每颗
		// 水珠的常量状态写进 RGBA16F 纹理（uPrev 绑反馈纹理仅为采样器合法，
		// 写出分支不采样）
		const preset = PRESETS[presetIndex];
		const program = this.programs[presetIndex] ?? null;
		const loc = this.locs[presetIndex] ?? null;
		if (!program || !loc) return;
		gl.bindVertexArray(this.vao);
		gl.useProgram(program);
		if (preset?.statePass && this.stateTex && this.stateFbo) {
			gl.bindFramebuffer(gl.FRAMEBUFFER, this.stateFbo);
			gl.viewport(0, 0, PAN_STATE_W, PAN_STATE_H);
			gl.uniform1f(loc.t, p.t);
			gl.uniform1f(loc.seed, p.seed);
			gl.uniform1f(loc.beat, p.beat);
			gl.uniform1f(loc.bass, p.bass);
			gl.uniform1f(loc.treble, p.treble);
			gl.uniform1f(loc.transition, p.transition);
			gl.uniform2f(loc.tilt, p.tiltX, p.tiltY);
			gl.uniform1f(loc.stateMode, 1);
			gl.activeTexture(gl.TEXTURE0);
			gl.bindTexture(gl.TEXTURE_2D, this.texAt(1 - this.flip));
			gl.uniform1i(loc.prev, 0);
			gl.drawArrays(gl.TRIANGLES, 0, 3);
		}

		// Pass A: scene + 反馈 -> 当前 FBO
		gl.bindFramebuffer(gl.FRAMEBUFFER, this.fboAt(this.flip));
		gl.viewport(0, 0, this.fboW, this.fboH);
		gl.uniform1f(loc.t, p.t);
		gl.uniform1f(loc.seed, p.seed);
		gl.uniform2f(loc.res, this.fboW, this.fboH);
		gl.uniform1f(loc.beat, p.beat);
		gl.uniform1f(loc.bass, p.bass);
		gl.uniform1f(loc.treble, p.treble);
		gl.uniform1f(loc.transition, p.transition);
		gl.uniform2f(loc.tilt, p.tiltX, p.tiltY);
		// pan：2=读状态纹理（常规）；0=回退逐像素（无浮点 FBO 的上下文）
		if (preset?.statePass) {
			gl.uniform1f(loc.stateMode, this.stateTex ? 2 : 0);
			if (this.stateTex) {
				gl.activeTexture(gl.TEXTURE1);
				gl.bindTexture(gl.TEXTURE_2D, this.stateTex);
				gl.uniform1i(loc.state, 1);
			}
		}
		gl.activeTexture(gl.TEXTURE0);
		gl.bindTexture(gl.TEXTURE_2D, this.texAt(1 - this.flip));
		gl.uniform1i(loc.prev, 0);
		gl.drawArrays(gl.TRIANGLES, 0, 3);

		// Pass B: FBO -> 屏幕
		gl.bindFramebuffer(gl.FRAMEBUFFER, null);
		gl.viewport(0, 0, this.canvas.width, this.canvas.height);
		if (this.blitProgram) {
			gl.useProgram(this.blitProgram);
			gl.activeTexture(gl.TEXTURE0);
			gl.bindTexture(gl.TEXTURE_2D, this.texAt(this.flip));
			gl.uniform1i(this.blitLoc, 0);
			gl.drawArrays(gl.TRIANGLES, 0, 3);
		}
		gl.bindVertexArray(null);
		this.flip = 1 - this.flip;
	}
}
