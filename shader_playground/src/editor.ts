/**
 * CodeMirror 6 编辑器封装：GLSL 高亮、行号、撤销历史、Tab 缩进、Cmd/Ctrl+S。
 */
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { defaultHighlightStyle, StreamLanguage, syntaxHighlighting } from '@codemirror/language';
import { shader } from '@codemirror/legacy-modes/mode/clike';
import { EditorState } from '@codemirror/state';
import { EditorView, keymap, lineNumbers } from '@codemirror/view';

export interface EditorHandle {
	/** 整体替换内容（切换 preset 时用） */
	setText(text: string): void;
	getText(): string;
	focus(): void;
	view: EditorView;
}

export interface EditorOptions {
	/** 文档变化（用户输入）回调 */
	onDocChanged(text: string): void;
	/** Cmd/Ctrl+S 保存回调，返回 true 表示已处理 */
	onSave(): boolean;
}

const glslLang = StreamLanguage.define(shader);

export function createEditor(parent: HTMLElement, opts: EditorOptions): EditorHandle {
	const state = EditorState.create({
		doc: '',
		extensions: [
			lineNumbers(),
			history(),
			keymap.of([
				...defaultKeymap,
				...historyKeymap,
				indentWithTab,
				{
					key: 'Mod-s',
					preventDefault: true,
					run: () => opts.onSave(),
				},
			]),
			glslLang,
			syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
			EditorView.lineWrapping,
			EditorView.updateListener.of((update) => {
				if (update.docChanged) {
					opts.onDocChanged(update.state.doc.toString());
				}
			}),
		],
	});
	const view = new EditorView({ state, parent });
	return {
		view,
		setText(text: string): void {
			view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
		},
		getText(): string {
			return view.state.doc.toString();
		},
		focus(): void {
			view.focus();
		},
	};
}
