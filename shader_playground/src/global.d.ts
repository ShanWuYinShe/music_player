import type { AudioSim } from './audioSim';

declare global {
	interface Window {
		/** 调试钩子：控制台 / 自动化脚本用 */
		__viz: {
			state: Record<string, unknown>;
			audio: AudioSim;
			renderFrame(): void;
			compileAllShaders(): void;
			selectPreset(idx: number): void;
		};
	}
}
