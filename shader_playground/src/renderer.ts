/**
 * WebGL2 渲染管线：与手机端 cpp/visualizer.cpp 一致的
 * 全屏三角形 + 反馈 FBO ping-pong + 内部降采样 + blit 上屏。
 * 差异仅在 GLSL ES 1.00 → 3.00 的补丁（见 glslPatch.ts）。
 */
import { type Diagnostic, ShaderError, toDiagnostic } from './errors';
import {
	BLIT_HEADER_LINES,
	FRAG_HEADER_LINES,
	hasEntryPoint,
	patchBlitForWebGL2,
	patchFragForWebGL2,
	patchVertForWebGL2,
	VERT_HEADER_LINES,
} from './glslPatch';
import { PRESETS } from './presets';

export interface RenderParams {
	t: number;
	seed: number;
	beat: number;
	bass: number;
	treble: number;
	transition: number;
	/** 内部分辨率比例（对应手机端 kRenderScale） */
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
	prev: WebGLUniformLocation | null;
}

function compileShader(
	gl: WebGL2RenderingContext,
	type: number,
	src: string,
	label: string,
	/** 该阶段注入头的行数；编译器行号减去它才是源文件行号 */
	headerLines: number,
): WebGLShader {
	const sh = gl.createShader(type);
	if (!sh) throw new ShaderError('compile', label, 'createShader 返回空（上下文可能已丢失）');
	gl.shaderSource(sh, src);
	gl.compileShader(sh);
	if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
		const log = (gl.getShaderInfoLog(sh) || '（驱动未返回日志）').replace(/\0/g, '');
		const lineMatch = log.match(/ERROR:\s*\d+:(\d+)/);
		gl.deleteShader(sh);
		const patchedLine = lineMatch?.[1] ? parseInt(lineMatch[1], 10) : undefined;
		throw new ShaderError(
			'compile',
			label,
			log.trim(),
			patchedLine !== undefined ? patchedLine - headerLines : undefined,
		);
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
		prev: gl.getUniformLocation(p, 'uPrev'),
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
	}

	/**
	 * 编译全部 program（blit + 4 场景）。任一失败：保留旧 program、返回诊断；
	 * 全部成功：替换并返回 null。草稿（无 main()）的场景文件跳过编译、
	 * 沿用旧 program，返回 skipDraft 标记供状态栏提示。
	 */
	compileAll(sources: Record<string, string>): {
		diag: Diagnostic | null;
		skippedDrafts: string[];
	} {
		const gl = this.gl;
		const skippedDrafts: string[] = [];
		try {
			const blitSrc = patchBlitForWebGL2(sources['blit.frag'], 'blit.frag');
			const vs = compileShader(
				gl,
				gl.VERTEX_SHADER,
				patchVertForWebGL2(sources['visualizer.vert']),
				'visualizer.vert',
				VERT_HEADER_LINES,
			);
			const fs = compileShader(gl, gl.FRAGMENT_SHADER, blitSrc, 'blit.frag', BLIT_HEADER_LINES);
			const newBlit = linkProgram(gl, vs, fs, 'blit');
			gl.deleteShader(vs);
			gl.deleteShader(fs);
			if (this.blitProgram) gl.deleteProgram(this.blitProgram);
			this.blitProgram = newBlit;
			this.blitLoc = gl.getUniformLocation(newBlit, 'uTex');
		} catch (err) {
			return { diag: toDiagnostic(err, 'blit 管线'), skippedDrafts };
		}

		for (const preset of PRESETS) {
			const src = sources[preset.file];
			if (typeof src !== 'string') {
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
				const fragSrc = patchFragForWebGL2(src, preset.file);
				const vs = compileShader(
					gl,
					gl.VERTEX_SHADER,
					patchVertForWebGL2(sources['visualizer.vert']),
					'visualizer.vert',
					VERT_HEADER_LINES,
				);
				const fs = compileShader(gl, gl.FRAGMENT_SHADER, fragSrc, preset.file, FRAG_HEADER_LINES);
				const p = linkProgram(gl, vs, fs, preset.name);
				gl.deleteShader(vs);
				gl.deleteShader(fs);
				if (this.programs[preset.id]) gl.deleteProgram(this.programs[preset.id] ?? null);
				this.programs[preset.id] = p;
				this.locs[preset.id] = getSceneLocs(gl, p);
			} catch (err) {
				return { diag: toDiagnostic(err, preset.label), skippedDrafts };
			}
		}
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
		const oldT0 = this.texAt(0);
		if (oldT0) {
			gl.deleteTexture(oldT0);
			gl.deleteTexture(this.texAt(1));
			gl.deleteFramebuffer(this.fboAt(0));
			gl.deleteFramebuffer(this.fboAt(1));
		}
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

		// Pass A: scene + 反馈 -> 当前 FBO
		gl.bindFramebuffer(gl.FRAMEBUFFER, this.fboAt(this.flip));
		gl.viewport(0, 0, this.fboW, this.fboH);
		gl.bindVertexArray(this.vao);
		const program = this.programs[presetIndex] ?? null;
		const loc = this.locs[presetIndex] ?? null;
		if (!program || !loc) return;
		gl.useProgram(program);
		gl.uniform1f(loc.t, p.t);
		gl.uniform1f(loc.seed, p.seed);
		gl.uniform2f(loc.res, this.fboW, this.fboH);
		gl.uniform1f(loc.beat, p.beat);
		gl.uniform1f(loc.bass, p.bass);
		gl.uniform1f(loc.treble, p.treble);
		gl.uniform1f(loc.transition, p.transition);
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
