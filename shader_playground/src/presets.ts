/** 预设（风格）清单，与手机端 kVizFragPresets / VisualizerCore 的轮换顺序一致 */
export interface Preset {
	id: number;
	/** 磁盘 /shaders/ 下的源文件名 */
	file: string;
	/** 程序名（截图文件名、错误标题用） */
	name: string;
	label: string;
	/** 文件列表圆点颜色 */
	color: string;
}

export const PRESETS: Preset[] = [
	{ id: 0, file: 'fractal.frag', name: 'fractal', label: '无限分形', color: '#ff7a59' },
	{ id: 1, file: 'pan.frag', name: 'pan', label: '热锅水珠', color: '#5db7ff' },
	{ id: 2, file: 'aurora.frag', name: 'aurora', label: '全屏极光', color: '#7af0a4' },
	{ id: 3, file: 'spectrum.frag', name: 'spectrum', label: '霓虹频谱', color: '#dba84e' },
];

export const VERT_FILE = 'visualizer.vert';
export const BLIT_FILE = 'blit.frag';
/**
 * 场景共享公共库（glslPatch 注入到头与场景源之间；端侧
 * gen_shader_header.py 读同一磁盘文件做同样注入）
 */
export const COMMON_FILE = 'common.glsl';
