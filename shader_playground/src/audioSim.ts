/**
 * 与手机端 VisualizerCore.ets / VisualizerView.ets 完全等价的纯函数实现。
 * 设备端公式（VisualizerView 帧驱动）：
 *   beat   = beatEnvelope(t, bpmFromSeed(seed), beatPhase)   // 裸值，无缩放
 *   bass   = (spec[0] + spec[1]) / 2
 *   treble = (spec[6] + spec[7]) / 2
 * 唯一的工具差异：手动「触发节拍」叠加 beatBoost（设备无此输入）。
 * 改动这里任何系数之前，先确认与 ArkTS 侧保持一致。
 */

const FNV_OFFSET = 0x811c9dc5 >>> 0;
const FNV_PRIME = 0x01000193;

export function fnv1a(str: string): number {
	let h = FNV_OFFSET;
	for (let i = 0; i < str.length; i++) {
		h = Math.imul(h ^ str.charCodeAt(i), FNV_PRIME) >>> 0;
	}
	return h;
}

export function hash01(n: number): number {
	let h = Math.imul((n | 0) ^ ((n | 0) >>> 16), 0x45d9f3b) >>> 0;
	h = Math.imul(h ^ (h >>> 16), 0x45d9f3b) >>> 0;
	return (h >>> 8) / 0x1000000;
}

export function seedFromId(id: string): number {
	return fnv1a(id);
}

export function bpmFromSeed(seed: number): number {
	return 90 + Math.floor(hash01(seed + 0x5f3a) * 61);
}

export function beatEnvelope(tMs: number, bpm: number, phase: number): number {
	const periodMs = 60000 / Math.max(40, Math.min(220, bpm));
	let x = (tMs / periodMs) % 1;
	if (x < 0) x += 1;
	x = (x + phase) % 1;
	return 0.25 + 0.75 * Math.exp(-4 * x);
}

export function synthSpectrum(seed: number, tMs: number, count: number): number[] {
	const out = new Array<number>(count);
	for (let i = 0; i < count; i++) {
		const p = count > 1 ? i / (count - 1) : 0;
		const base = 0.34 + 0.38 * (1 - p);
		const w1 = 0.0021 + 0.0035 * p;
		const w2 = 0.0009 + 0.0022 * p;
		const ph1 = hash01(seed + i * 7 + 1) * Math.PI * 2;
		const ph2 = hash01(seed + i * 13 + 5) * Math.PI * 2;
		const amp1 = 0.3 + 0.22 * hash01(seed + i * 29 + 11);
		const amp2 = 0.14 + 0.16 * hash01(seed + i * 41 + 17);
		const v = base + amp1 * Math.sin(tMs * w1 + ph1) + amp2 * Math.sin(tMs * w2 + ph2);
		out[i] = Math.min(1, Math.max(0.04, v));
	}
	return out;
}

/** 音乐律动合成器状态：播放时钟推进 + beat 脉冲衰减 + 每帧采样 */
export class AudioSim {
	seed = 12345678;
	/** 由 seed 派生（与设备 bpmFromSeed 一致），不作为可调参数 */
	bpm = bpmFromSeed(12345678);
	/** 播放时钟（ms），暂停时不推进 */
	playClock = 0;
	/** 手动「触发节拍」叠加的脉冲量（设备无此输入） */
	beatBoost = 0;
	private beatPhase = 0;

	setSeed(seed: number): void {
		this.seed = seed >>> 0;
		this.bpm = bpmFromSeed(this.seed);
		this.beatPhase = (this.seed % 997) / 997;
		this.playClock = 0;
	}

	/** 推进时钟并衰减 beatBoost；dtMs 为距上次调用的真实间隔 */
	advance(dtMs: number): void {
		this.playClock += dtMs;
		if (this.beatBoost > 0) {
			this.beatBoost = Math.max(0, this.beatBoost - dtMs / 280);
		}
	}

	tapBeat(): void {
		this.beatBoost = Math.min(1, this.beatBoost + 0.6);
	}

	/** 当前帧的 beat/bass/treble，取值范围 [0,1]；公式与设备端一致（裸值） */
	sample(): { beat: number; bass: number; treble: number } {
		const t = this.playClock;
		const beat = Math.min(1, beatEnvelope(t, this.bpm, this.beatPhase) + this.beatBoost);
		const spec = synthSpectrum(this.seed, t, 8);
		const low = (spec[0] ?? 0.04) + (spec[1] ?? 0.04);
		const high = (spec[6] ?? 0.04) + (spec[7] ?? 0.04);
		return { beat, bass: low / 2, treble: high / 2 };
	}
}
