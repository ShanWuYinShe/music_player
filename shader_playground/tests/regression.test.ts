import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, test } from 'vitest';

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const SHADER_ROOT = resolve(REPO_ROOT, 'music_app/entry/src/main/cpp/shaders');

function readShader(name: string): string {
	return readFileSync(resolve(SHADER_ROOT, name), 'utf8');
}

describe('fractal v3.2 形态轮换连续性（回归保护）', () => {
	// 历史 bug：v3.1 在周期两端各做一段 crossfade，末尾侧已 100% 新场、开头侧
	// 又从旧场 0% 淡起——边界处画面从新场硬跳回旧场再淡一遍，每 22s 必跳变；
	// 冷启动 ts=0 还先显示幻影"上一场"。v3.2 修复：开头不混合，末尾单段淡入
	// 下一场——边界两侧严格连续。下述两条断言锁定该修复不被回退。
	const fractal = readShader('fractal.frag');

	test('周期内不在"开头"对旧场做混合（v3.1 头尾双 crossfade 已废弃）', () => {
		// 任何 `ph < xf` / `ph < FORM_XF_SEC / FORM_PERIOD` 形式都是旧场开头混合
		expect(fractal).not.toMatch(/if\s*\(\s*ph\s*<\s*xf\b/);
		expect(fractal).not.toMatch(/if\s*\(\s*ph\s*<\s*FORM_XF_SEC/);
	});

	test('反馈拖尾 diveW 不再按"ph < xf"混入前向缩放率（v3.1 bug）', () => {
		// v3.1 在 ph < xf 期间把 diveW 提到 1-k，让旧场拖尾用深潜缩放率；
		// 这正是开头侧"硬跳回旧场再淡一遍"的视觉来源之一。注意 modeForShow
		// 内部仍合法地使用 showIdx - 1.0 来"避免形态重复"——那是另一回事。
		expect(fractal).not.toMatch(/if\s*\(\s*ph\s*<\s*xf\b/);
		expect(fractal).not.toMatch(/ph\s*<\s*xf[\s\S]{0,80}diveW/);
	});

	test('周期末尾仍向下一场 crossfade（防止反向回退到 v3.0 无混合）', () => {
		// 单侧混合逻辑是 v3.2 的正向修复；删掉它就回到 v3.0 的硬切。
		expect(fractal).toMatch(/ph\s*>\s*1\.0\s*-\s*xf/);
	});
});

describe('aurora v7.1 底边下方帘体断崖（回归保护）', () => {
	// 历史 bug：v6 以前用 `dd = max(d, 0)` 让 body = exp(-dd/H) 在底边以下像素
	// 恒为 1——帘体在底边下方平铺全亮，"挂在天上一片亮布/墙"的几何根源。
	// v7.1 修复：底边下方加 `exp(dneg / (H * 0.30))` 快速断崖，宽光晕同加
	// `exp(dneg / (H * 0.55))`。锁定：
	const aurora = readShader('aurora.frag');

	test('帘体 body 在底边下方以 ≤0.4×H 速度断崖（v7.1 核心修复）', () => {
		// 用 dneg 作为指数项，且 body 那一项系数 ≤ 0.4（H 越小衰减越快）——
		// 宽光晕（0.55）等更慢的衰减是允许的，那一层比 body 平缓是对的。
		const matches = aurora.match(/exp\(\s*dneg\s*\/\s*\(\s*H\s*\*\s*([\d.]+)\s*\)/g) ?? [];
		expect(matches.length).toBeGreaterThanOrEqual(2);
		const coefs = matches.map((m) => Number(m.match(/([\d.]+)\s*\)/)![1]));
		// 至少一项 ≤ 0.4（body 的快速断崖）；其它项允许更大（宽光晕）
		expect(Math.min(...coefs)).toBeLessThanOrEqual(0.4);
	});

	test('底边下方没有用 dd=max(d,0) 把 dneg 截掉', () => {
		// 真正的破坏性 bug 模式：算 body 时用 `dd = max(d, 0.0)`，且只用 dd 一个
		// 项——这正是 v7.1 之前"亮布"的几何根源。
		const bodyBlock = aurora.match(/float\s+body\s*=\s*[^;]+;/);
		expect(bodyBlock).not.toBeNull();
		expect(bodyBlock![0]).toContain('dneg');
	});

	test('窗光白化阈值不把整片帘体打成白糊（emL 起点 ≥ 0.5）', () => {
		// v7.1 的白化是"亮芯白化"——只有最亮的英雄柱/针柱芯部向白偏移；
		// 把 smoothstep 起点放到 ≤ 0.4 会让帘体通体向白色靠拢，丧失绿色饱和度。
		// 当前实现 0.75 处于合理区间；断言底线是 ≥ 0.5，防止回退到全屏白化。
		const m = aurora.match(/smoothstep\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*eL\s*\)/);
		expect(m).not.toBeNull();
		const lo = Number(m![1]);
		expect(lo).toBeGreaterThanOrEqual(0.5);
	});
});

describe('pan v15 真 3D 锅几何（回归保护）', () => {
	// 历史 bug 链：
	//   v7  锅底铺满整个椭圆 = 平底锅
	//   v8  改用"底缘常量"bRAt（近侧 0.92 / 远侧 0.58）——仍是伪 3D：把锅口
	//       椭圆的中心当成了锅心。真实球冠 + 斜视投影下，锅心必须落在椭圆
	//       中心**下方** D·sinα，这个错位把远侧内壁撑成锅半径的 42%，再被
	//       innerWallColor 涂成比锅底还亮的均匀灰（0.24~0.34 vs 锅底 0.227）
	//       → 用户看到的"锅里装了 1/3 高的水"（v8~v14 一直存在）。
	//   v15 几何全部由光线-球面求交给出，内壁宽度/底缘/法线都是算出来的。
	const pan = readShader('pan.frag');

	test('锅几何由光线-球面求交给出（panHit 存在且做 z≤D 的可见性裁剪）', () => {
		expect(pan).toMatch(/bool\s+panHit\s*\(/);
		// 取"锅口平面以下的最大根"：远侧取小根（大根在球上半部不存在）、
		// 近侧取大根（锅沿遮挡内壁）
		expect(pan).toMatch(/zHi\s*<=\s*D\s*\)\s*\?\s*zHi\s*:\s*zLo/);
		expect(pan).toMatch(/if\s*\(\s*z\s*>\s*D/);
	});

	test('锅心在原点、锅深与球半径自洽（D=Rs−√(Rs²−1)）', () => {
		const depth = Number((pan.match(/PAN_DEPTH\s*=\s*([\d.]+)/) ?? [])[1] ?? NaN);
		const rsExpr = pan.match(/PAN_SPHERE_R\s*=\s*\([^;]+;/);
		expect(rsExpr).not.toBeNull();
		// 公式必须是 (1+D²)/(2D)
		expect(rsExpr![0]).toMatch(/\(1\.0\s*\+\s*PAN_DEPTH\s*\*\s*PAN_DEPTH\)\s*\/\s*\(2\.0\s*\*\s*PAN_DEPTH\)/);
		// 由 D 反算 Rs，校验球冠自洽（锅心 z=0、锅口 z=D）
		const Rs = (1 + depth * depth) / (2 * depth);
		expect(Math.abs(Rs - Math.sqrt(Rs * Rs - 1) - depth)).toBeLessThan(1e-6);
	});

	test('法线指向锅内表面（锅心处为 +z），不能写成球面外法线', () => {
		// 外法线 normalize(P − 球心) 指向下方（锅面是球的下半部），取反才是
		// 我们看到的那一面。写成外法线会让锅渲染成凸面、光照全反。
		expect(pan).toMatch(/N\s*=\s*normalize\(vec3\(\s*-P\.x\s*,\s*-P\.y\s*,\s*Rs\s*-\s*z\s*\)\)/);
		expect(pan).not.toMatch(/normalize\(vec3\(P\.x, P\.y, z - Rs\)\)/);
	});

	test('水滴最高点 ≈ 1/3 锅高（θmax 由 z=D/3 反解，非拍脑袋常量）', () => {
		const depth = Number((pan.match(/PAN_DEPTH\s*=\s*([\d.]+)/) ?? [])[1] ?? NaN);
		const thMax = Number((pan.match(/DROP_THETA_MAX\s*=\s*([\d.]+)/) ?? [])[1] ?? NaN);
		const Rs = (1 + depth * depth) / (2 * depth);
		const zTop = Rs * (1 - Math.cos(thMax));
		const ratio = zTop / depth;
		expect(ratio).toBeGreaterThan(0.25);   // 不能贴着锅底不动
		expect(ratio).toBeLessThan(0.42);      // 不能超过 1/3 太多（会读作"水"）
	});

	test('水滴极角是摆动（重力滑梯），不是绕心匀速盘旋', () => {
		// 必须有 θ = θmax·|sin(ωt+φ)|^p 形态：锅心速度最大、θmax 处折返
		expect(pan).toMatch(/th\s*=\s*DROP_THETA_MAX[\s\S]{0,400}sin\(/);
		// 反向断言：ORBIT 绕心旋转已被移除（v11 的螺旋圆 = 用户明确反对）
		expect(pan).not.toMatch(/pos\s*=\s*rot\(oa\)\s*\*\s*pos/);
	});

	test('不再用伪底缘常量驱动构图（bRAt 不得参与 main 的合成）', () => {
		// bRAt / innerWallColor 仅作为历史函数保留（回归测试自身会引用），
		// 但 main 里不能再拿它们做内壁合成——那是"水"的来源
		expect(pan).not.toMatch(/col\s*=\s*mix\(col,\s*innerWallColor/);
		expect(pan).not.toMatch(/float\s+maxR\s*=\s*mix\(bR/);
	});

	test('蒸汽从锅口开口面升起（v7 的"远侧一条线"位置错已修）', () => {
		// v8 的关键修复：蒸汽 src = 锅口椭圆内部（锅心最强、沿口衰减），
		// 而不是夹角项只让远侧 y>0 起一条线。检查 src 用 smoothstep(openR)
		// 即可——只要开口面半径参与 src 计算，就是 v8 行为。
		const srcDecl = pan.match(/float\s+src\s*=\s*[^;]+;/);
		expect(srcDecl).not.toBeNull();
		expect(srcDecl![0]).toMatch(/smoothstep\([^)]*openR/);
		// 反向断言：v7 的位置错是"src 仅在远侧 p.y 起"，应不存在这种坏 pattern
		expect(pan).not.toMatch(/src\s*=\s*clamp\(\s*p\.y/);
	});
});