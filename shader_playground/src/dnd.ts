/**
 * 全局文件拖拽：把着色器文件从 Finder 拖进窗口即**替换当前目标**。
 * 语义是替换而非追加——一次只取拖入的第一个文件，避免多文件依序
 * 填槽导致的"改了别的文件"错乱；目标文件名显示在遮罩上。
 */

export interface LoadedFile {
	name: string;
	text: string;
}

export interface DndOptions {
	/** 拖拽悬停时显示/隐藏遮罩 */
	overlay: HTMLElement;
	/** 遮罩上展示的将被替换的目标文件名（随当前选中项变化） */
	getTargetName(): string;
	onFile(file: LoadedFile): void;
}

function isShaderFile(name: string): boolean {
	return /\.(frag|vert|glsl|vs|fs)$/i.test(name);
}

export function installDnd(opts: DndOptions): () => void {
	const { overlay } = opts;
	const targetEl = overlay.querySelector<HTMLElement>('#drop-target');
	let depth = 0;

	const hasFiles = (e: DragEvent): boolean =>
		Array.from(e.dataTransfer?.types ?? []).includes('Files');

	const onDragEnter = (e: DragEvent): void => {
		if (!hasFiles(e)) return;
		e.preventDefault();
		depth++;
		if (targetEl) targetEl.textContent = opts.getTargetName();
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
		const first = Array.from(e.dataTransfer?.files ?? []).find((f) => isShaderFile(f.name));
		if (!first) return;
		// drop 事件处理器返回前 File 对象同步可读，先取文本再回调
		first
			.text()
			.then((text) => opts.onFile({ name: first.name, text }))
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
