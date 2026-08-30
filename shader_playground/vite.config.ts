import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { type Connect, defineConfig, type Plugin } from 'vite';

// 仓库根（shader_playground/ 的上一级）
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// 磁盘上的 shader 源目录：与手机端 CMake 读取的是同一份，预览永远同源
export const SHADER_DIR = path.resolve(repoRoot, 'music_app/entry/src/main/cpp/shaders');

/** 需要随 dev/preview/build 提供的着色器源文件（common.glsl 是场景共享公共库） */
export const SHADER_FILES = [
	'visualizer.vert',
	'common.glsl',
	'fractal.frag',
	'pan.frag',
	'aurora.frag',
	'blit.frag',
] as const;

const MIME: Record<string, string> = {
	'.frag': 'text/plain; charset=utf-8',
	'.vert': 'text/plain; charset=utf-8',
	'.glsl': 'text/plain; charset=utf-8',
};

/** 解析 /shaders/<name> 请求；命中返回文件路径，未命中返回 null */
function resolveShaderRequest(url: string | undefined): string | null {
	const name = decodeURIComponent(
		new URL(url ?? '/', 'http://localhost').pathname.replace(/^\/+/, ''),
	);
	if (!name || name.includes('..')) return null;
	const file = path.normalize(path.join(SHADER_DIR, name));
	if (!file.startsWith(SHADER_DIR + path.sep) || !fs.existsSync(file)) return null;
	return fs.statSync(file).isFile() ? file : null;
}

function shaderMiddleware(): Plugin {
	const handler: Connect.NextHandleFunction = (req, res) => {
		const file = resolveShaderRequest(req.url);
		if (!file) {
			res.statusCode = 404;
			res.setHeader('Content-Type', 'text/plain; charset=utf-8');
			res.end('shader 源文件不存在');
			return;
		}
		res.setHeader('Content-Type', MIME[path.extname(file)] ?? 'text/plain; charset=utf-8');
		res.setHeader('Cache-Control', 'no-store');
		fs.createReadStream(file).pipe(res);
	};
	return {
		name: 'shader-playground-source',
		apply: 'serve',
		configureServer(server) {
			server.middlewares.use('/shaders', handler);
		},
		configurePreviewServer(server) {
			server.middlewares.use('/shaders', handler);
		},
	};
}

// 构建期把当时的 shader 源文件快照进 dist/shaders/
function shaderSnapshotPlugin(): Plugin {
	return {
		name: 'shader-playground-snapshot',
		apply: 'build',
		buildStart() {
			if (!fs.existsSync(SHADER_DIR)) {
				throw new Error(
					`shader 源目录不存在：${SHADER_DIR}\n本工具必须位于 music_player 仓库内运行（shaders 由 music_app 批次提供）`,
				);
			}
			for (const name of SHADER_FILES) {
				const file = path.join(SHADER_DIR, name);
				if (!fs.existsSync(file)) {
					throw new Error(`shader 源文件缺失：${file}`);
				}
				this.emitFile({
					type: 'asset',
					fileName: `shaders/${name}`,
					source: fs.readFileSync(file),
				});
			}
		},
	};
}

export default defineConfig({
	plugins: [shaderMiddleware(), shaderSnapshotPlugin()],
	server: { port: 8791 },
	preview: { port: 8792 },
	build: { target: 'es2022' },
});
