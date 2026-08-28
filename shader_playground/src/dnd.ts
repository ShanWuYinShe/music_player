/**
 * 全局文件拖拽：把 .frag / .vert 文件从 Finder 拖进窗口即可载入预览。
 * 旧版页面没有 preventDefault，拖文件进来浏览器会直接打开文件内容，
 * 这里统一接管并以遮罩提示落点。
 */

export interface LoadedFile {
	name: string;
	text: string;
}

export interface DndOptions {
	/** 拖拽悬停时显示/隐藏遮罩 */
	overlay: HTMLElement;
	onFiles(files: LoadedFile[]): void;
}

function isShaderFile(name: string): boolean {
	return /\.(frag|vert|glsl|vs|fs)$/i.test(name);
}

export function installDnd(opts: DndOptions): () => void {
	const { overlay } = opts;
	let depth = 0;

	const hasFiles = (e: DragEvent): boolean =>
		Array.from(e.dataTransfer?.types ?? []).includes('Files');

	const onDragEnter = (e: DragEvent): void => {
		if (!hasFiles(e)) return;
		e.preventDefault();
		depth++;
		overlay.classList.add('visible');
	};

	const onDragOver = (e: DragEvent): void => {
		if (!hasFiles(e)) return;
		e.preventDefault();
		if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy';
	};

	const onDragLeave = (e: DragEvent): void => {
		if (!hasFiles(e)) return;
		e.preventDefault();
		depth = Math.max(0, depth - 1);
		if (depth === 0) overlay.classList.remove('visible');
	};

	const onDrop = (e: DragEvent): void => {
		if (!hasFiles(e)) return;
		e.preventDefault();
		depth = 0;
		overlay.classList.remove('visible');
		const files = Array.from(e.dataTransfer?.files ?? []).filter((f) => isShaderFile(f.name));
		if (files.length === 0) return;
		// drop 事件处理器返回前 File 对象同步可读，先取文本再回调
		Promise.all(files.map(async (f) => ({ name: f.name, text: await f.text() })))
			.then((loaded) => opts.onFiles(loaded))
			.catch((err: unknown) => {
				console.error('读取拖入文件失败', err);
			});
	};

	window.addEventListener('dragenter', onDragEnter);
	window.addEventListener('dragover', onDragOver);
	window.addEventListener('dragleave', onDragLeave);
	window.addEventListener('drop', onDrop);
	return () => {
		window.removeEventListener('dragenter', onDragEnter);
		window.removeEventListener('dragover', onDragOver);
		window.removeEventListener('dragleave', onDragLeave);
		window.removeEventListener('drop', onDrop);
	};
}
