import { describe, expect, test } from 'bun:test';
import {
	AudioSim,
	beatEnvelope,
	bpmFromSeed,
	fnv1a,
	hash01,
	seedFromId,
	synthSpectrum,
} from '../src/audioSim';

describe('fnv1a / seed', () => {
	test('FNV-1a 已知向量', () => {
		// 标准测试向量（32 位 FNV-1a）
		expect(fnv1a('')).toBe(0x811c9dc5);
		expect(fnv1a('a')).toBe(0xe40c292c);
	});

	test('seedFromId 稳定且为 uint32', () => {
		const s = seedFromId('song-123');
		expect(s).toBe(seedFromId('song-123'));
		expect(s).toBeGreaterThanOrEqual(0);
		expect(s).toBeLessThanOrEqual(0xffffffff);
	});

	test('bpmFromSeed 落在 [90, 150]', () => {
		for (let i = 0; i < 50; i++) {
			const bpm = bpmFromSeed(i * 7919);
			expect(bpm).toBeGreaterThanOrEqual(90);
			expect(bpm).toBeLessThan(151);
		}
	});
});

describe('hash01 / spectrum', () => {
	test('hash01 输出 [0,1)', () => {
		for (let i = -100; i < 100; i++) {
			const v = hash01(i * 1234567);
			expect(v).toBeGreaterThanOrEqual(0);
			expect(v).toBeLessThan(1);
		}
	});

	test('synthSpectrum 夹在 [0.04, 1] 且长度正确', () => {
		const out = synthSpectrum(42, 12345, 8);
		expect(out).toHaveLength(8);
		for (const v of out) {
			expect(v).toBeGreaterThanOrEqual(0.04);
			expect(v).toBeLessThanOrEqual(1);
		}
	});

	test('count=1 不产生除零', () => {
		expect(synthSpectrum(7, 0, 1)).toHaveLength(1);
	});
});

describe('beatEnvelope', () => {
	test('负时间取模回卷后仍在范围内', () => {
		const v = beatEnvelope(-5000, 120, 0);
		expect(v).toBeGreaterThanOrEqual(0.25);
		expect(v).toBeLessThanOrEqual(1);
	});

	test('相位回卷：t=周期起点处包络最大', () => {
		const period = 60000 / 120;
		expect(beatEnvelope(period, 120, 0)).toBeCloseTo(1, 5);
	});
});

describe('AudioSim', () => {
	test('setSeed 重置时钟并派生相位', () => {
		const sim = new AudioSim();
		sim.advance(5000);
		sim.setSeed(999);
		expect(sim.playClock).toBe(0);
		expect(sim.seed).toBe(999);
	});

	test('beatBoost 衰减不小于 0', () => {
		const sim = new AudioSim();
		sim.tapBeat();
		sim.tapBeat();
		for (let i = 0; i < 400; i++) sim.advance(16);
		expect(sim.beatBoost).toBe(0);
	});

	test('sample 输出都在 [0,1]', () => {
		const sim = new AudioSim();
		sim.tapBeat();
		for (let i = 0; i < 100; i++) {
			sim.advance(16);
			const { beat, bass, treble } = sim.sample();
			expect(beat).toBeLessThanOrEqual(1);
			expect(bass).toBeLessThanOrEqual(1);
			expect(treble).toBeLessThanOrEqual(1);
			expect(beat).toBeGreaterThanOrEqual(0);
			expect(bass).toBeGreaterThanOrEqual(0);
			expect(treble).toBeGreaterThanOrEqual(0);
		}
	});
});

describe('AudioSim 与设备端公式对齐', () => {
	test('setSeed 派生 bpm（bpmFromSeed 同源）', () => {
		const sim = new AudioSim();
		sim.setSeed(424242);
		expect(sim.bpm).toBe(bpmFromSeed(424242));
	});

	test('sample 的 beat 与裸包络一致（无缩放）', () => {
		const sim = new AudioSim();
		sim.setSeed(777);
		sim.advance(1234);
		const { beat } = sim.sample();
		// 无手动脉冲时 = beatEnvelope 裸值（可能被 min(1) 截断，但包络 ≤1）
		expect(beat).toBeCloseTo(beatEnvelope(sim.playClock, sim.bpm, (777 % 997) / 997), 10);
	});
});
