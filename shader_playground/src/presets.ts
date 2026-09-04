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
	/** 内部反馈 FBO 分辨率比例——与端侧 visualizer.cpp 的 kPresetScale 逐项
	 * 对齐（pan/aurora 逐像素负载高且形态柔软，更低比例上屏放大视觉近
	 * 无损；fractal/spectrum 维持 1/2）。pipelineConsistency.test.ts 有
	 * 跨端一致性断言。 */
	renderScale: number;
	/** 水珠状态预通道：每帧先以 20×4 小视口（uStateMode=1）把每滴状态写进
	 * RGBA16F 纹理，主 pass texelFetch 取用（与端侧 kVizPresetPan 对应；
	 * WebGL 无 EXT_color_buffer_float 时按编译期开关退回逐像素路径） */
	statePass?: boolean;
}

export const PRESETS: Preset[] = [
	{
		id: 0,
		file: 'fractal.frag',
		name: 'fractal',
		label: '无限分形',
		color: '#ff7a59',
		renderScale: 0.5,
	},
	{
		id: 1,
		file: 'pan.frag',
		name: 'pan',
		label: '热锅水珠',
		color: '#5db7ff',
		renderScale: 0.45,
		statePass: true,
	},
	{
		id: 2,
		file: 'aurora.frag',
		name: 'aurora',
		label: '全屏极光',
		color: '#7af0a4',
		renderScale: 0.33,
	},
	{
		id: 3,
		file: 'spectrum.frag',
		name: 'spectrum',
		label: '霓虹频谱',
		color: '#dba84e',
		renderScale: 0.5,
	},
];

export const VERT_FILE = 'visualizer.vert';
export const BLIT_FILE = 'blit.frag';
/**
 * 场景共享公共库（glslPatch 注入到头与场景源之间；端侧
 * gen_shader_header.py 读同一磁盘文件做同样注入）
 */
export const COMMON_FILE = 'common.glsl';
