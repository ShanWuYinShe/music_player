// pan.frag：高温热炒菜锅上的水滴动力学（照片级 v17：真 3D 几何 + 真实莱顿
// 弗罗斯特物理 + 状态预通道性能重构）。
//
// v17 相对 v16（用户反馈：热锅水珠严重卡顿——在保证效果的前提下优化性能）：
//   1. **水珠状态预通道**：每颗水珠的完整状态（位置/半径/速度向/形状参数）
//      只依赖 (索引, t, seed, uBass)，是**每帧常量**，v16 以前却在 field()
//      里被逐像素重复计算（20 滴 × 每滴十余次 hash/sin/atan/vn/wander，
//      是本场景卡顿的主因）。现在 C++ 侧每帧先以 20×4 小视口、uStateMode=1
//      调起本 shader 把状态写进 RGBA16F 纹理（80 像素开销可忽略），主 pass
//      循环 texelFetch 取状态，循环体只剩距离/轮廓/累积（~4× 于循环本身）。
//      设备无浮点颜色缓冲扩展时，C++ 以 PAN_NO_STATE_TEX 编译期开关退回
//      逐像素路径（与状态通道共用同一 dropState() 函数，零行为分叉）。
//   2. **锅外像素跳过**：v16 的 field()/bg()/水珠着色/焦散/星芒全屏执行，
//      而锅椭圆之外 ~70% 像素的结果都被 panMask/dropMask 归零（纯浪费）。
//      v17 先算 panMask/wallMask/outerMask 再按掩模分支，锅外只走外壁/
//      台面/蒸汽路径（掩模阈值以下的混叠贡献 <0.4% 亮度，肉眼不可辨）。
//   3. **bg() 同参重复调用去重**：v12 注释声称"合并折射取样"，实际
//      bg(Ph2,Nh2,ts) 以相同入参被调用了两次、折射偏移 ruv 是死代码——
//      删除 ruv，水珠折射直接复用锅底色 panBase（输出逐像素等价，bg 全帧
//      只算一次）；蒸汽缕与台面木纹 fbm→fbm3（软特征降阶）。
//
// v16 相对 v15（用户反馈：锅里还有一圈一圈的螺旋圆环；莱顿弗罗斯特有物理
//   公式，不该用经验系数）：
//   1. **删螺旋圆环**：v10 的加热纹 = 规则同心圆（sin(r·28)，4.5 圈）+
//      角度项（sin(r·f + ang·1.7) 把同心圆拧成螺旋）+ 时间项（ts·DRIFT 让
//      纹路一直游动）三样叠加。改：温度场用各向异性噪声（真实热斑），只留
//      燃气火焰环的一圈**静态**灶痕（BURNER_R=0.52 单环、不带角度项、不带
//      时间项）；反照率调制也从 ts·DRIFT 的同心圆改成静态使用痕迹噪声。
//   2. **毛细长度 / Bond number 扁平化**：液滴形态由 Bo=(R/l_c)² 决定，
//      l_c=√(σ/ρg)≈2.7mm（水）。小珠（R<l_c）表面张力主导 → 球形；大珠
//      （R>>l_c）重力主导 → 摊成**厚度恒定**的扁饼 h≈2·l_c（与体积无关）。
//      ⟹ hDome 上限 = min(1, 2·l_c/R)，替代 v14 的固定 DROP_FLAT。
//   3. **Rayleigh 液滴振荡**：n=2 基模 f=(1/2π)·√(σ/ρR³)·√8 ⟹ f∝R^-3/2，
//      小珠颤得快（~20Hz）、大珠颤得慢（~1.6Hz），替代与半径无关的 9+7h2。
//   4. 保留 v15 的真 3D 光线-球面求交（删伪内壁环带 = 删"锅里的水"）。
//
// v14 相对 v13 的运动/形态重构（用户反馈：水滴是在"锅底悬空的高度平面"上
//   移动，应该贴着锅内侧做 3D 运动；而且"锅底只有水珠，不是有那么高的水"）：
//   1. **球面滑行（核心）**：v13 的 pos 是纯 2D 平面坐标——所有水珠都在底
//      缘椭圆内平移，读作"悬浮在锅底上方一个平面上的球"。现在把平面游走
//      量映射成球面极角 θ（θ=0 锅心、θ=SLIDE_THETA 内壁），水平投影
//      s=sin(θ) 让 ds/dθ=cos(θ)：锅心一掠而过、内壁徘徊——重力滑梯，快慢比
//      1/cos(θmax)≈4.6×，不再是匀速兜圈。
//   2. **高度视差**：球面高度 bowlZ 让爬高的珠在屏幕上向外偏（内壁在锅口
//      椭圆上，比锅底椭圆大）+ 向远侧上方偏。这是"贴着内侧滑"的判别特
//      征——平面运动永远做不出这种随高度变化的位移。
//   3. **可以爬上内壁**：裁剪半径从底缘 bR 放宽到 mix(bR, 1.0, WALL_CLIMB)，
//      绘制域同步放宽（dropMask），水珠能贴着内侧壁滑上一截。
//   4. **近大远小**：PERSP_SIZE 让爬上近侧内壁的珠略大、远侧略小。
//   5. **水珠扁平化**：DROP_FLAT=0.62 把元球穹顶压成贴地扁饼（中间平、边
//      缘一圈陡接触角）——锅底只有水珠，没有"立起来的一泡水"。
//
// v13 相对 v12 的形态修正（用户反馈：锅底还是平的、水滴太规则就是半球形）：
//   1. **锅底球面感（"平"的病根）**：不是贴图问题，是黑碳钢漫反射主导
//      （PAN_SPEC 只有 0.30），球冠法线的镜面反射渐变（锅心反射天花板亮、
//      锅沿反射暗墙）被淹没，锅底读作"均匀暗平面"。修：PAN_SPEC 0.30→0.48
//      + PAN_DIFF 0.55→0.42（镜面占比提升），并显式补一道径向明暗
//      `c *= 0.55 + 0.45*n.z`（球冠法线 n.z 锅心竖直→锅沿倾斜）——球面曲率
//      可读。
//   2. **水滴不规则（"半球形"的病根）**：wob 扰动幅度太小（±20%），经元球
//      高度场平均后肉眼读作圆。修：WOB_BIG_AMP 0.20→0.40、WOB_SMALL_AMP
//      0.05→0.12、WOB_STRETCH 0.40→0.70（明显泪滴形）、WOB_BOIL_AMP
//      0.50→0.85（沸腾剧烈翻腾），并加 hash 扇区扰动（圆周分 6 扇区各随机
//      凹凸——规则 sin 谐波是"花瓣"，扇区 hash 才是"有机不规则"）。
//
// v12 相对 v11 的性能优化（用户反馈：运行很卡，网页快卡死——根因是
// field() 逐像素 × 逐滴循环太重 + bg() 每像素 3 次调用，在 playground 的
// SwiftShader 软渲染（无 GPU 加速）下尤其爆炸。逐项降计算量，视觉尽量不变）：
//   1. DROPLET_COUNT 44→28（-36% field 循环；22 主滴 + 6 卫星，保留大小珠层次）
//   2. bg(ruv) 合并：折射 + 薄缘透光原本各调一次完整 bg（tempField+fbm+
//      envMap 各两遍），合并为一次复用——bg 总调用 3→2 次
//   3. 温度场 fbm→vn（4 倍频→1 阶，×2 次 bg 调用）
//   4. wob 角向谐波 5→3 项（每滴少 2 次 sin）
//   5. sizzle 噪声 vn(per-pixel 4 hash)→hash11(每滴 1 hash)
//   6. 白烟 fbm→vn、锅底使用痕迹 fbm→vn
//   视觉等价：这些噪声的降阶在液滴/锅底的小尺度上肉眼难辨，只省计算。
//
// v11 相对 v10 的四项修正（用户反馈四点：锅底还是平的、水珠材质差、
// 运动单调、像一滩积水）：
//   1. **球体锅身**：BOWL_RADIUS 1.30→1.10——球面曲率 1/R 变大（锅心从
//      "近平"变成明显弯曲，底缘法线 ~57°），WALL_W 0.28→0.32 内壁更宽
//      = 深炒锅的"看进去"透视。锅心不再是一块平镜面。
//   2. **水珠材质强化**：GLINT 2.0→2.6（窗光针尖更锐更亮，湿润感本体）、
//      DROP_DIFF 0.10→0.16（微漫反射更亮）、BULB_GLOW 0.35→0.50（暖色泛
//      光更明显）、REFRACT_LEN 0.28→0.34（透镜放大更强 = 水珠更"实心"）、
//      新增 SKY_GLINT=0.45 天光高光（pow 12 中锐顶部泛光，湿润水面的
//      光泽过渡档）。
//   3. **运动随机化**：BOWL_GATHER 0.58→0.85（活动范围大幅放开——真实
//      物理里水珠被蒸气垫托着在球面上滑行/翻滚，重力只是弱引导不会钉
//      死在锅心）+ 每滴一个慢变方向的随机"热流推挤"漂移（wander 混沌驱
//      动，DRIFT_AMP=0.22）——轨迹从"规则绕圈"变成"被热流推着乱窜"。
//   4. **消除积水感**：BOWL_DARK 0.30→0.38（锅心聚油更暗——水珠是亮体，
//      锅心不该亮成水面）+ 水珠分散后不再"聚成一滩"。
//
// v10 相对 v9 的"贴近真实热炒场景"重大返工（参考实拍：黑碳钢锅+燃气灶
// 圈+锅心红热+水珠沸腾爆裂+锅口白烟弥漫）：
//   1. **锅底材质从拉丝不锈钢改黑碳钢/铸铁**：v9 的亮反射（PAN_SPEC=0.72、
//      albedo 0.14）是"厨房用品"质感，但参考图是**磨砂黑碳钢**（低反照率
//      0.05~0.08、镜面锐度高但能量低）——这是炒锅的本色：深色 + 吸光 +
//      高对比微反射。PAN_DIFF 0.18→0.55（哑光漫反射主导，不是金属镜面）、
//      PAN_SPEC 0.72→0.30（微镜面，不抢戏）、albedo 0.14→0.07。
//   2. **锅底温度场 + 同心圆加热纹 + 锅心红热**：参考图锅底有明显的同心圆
//      燃气加热纹（亮环交替）和锅心红热区。v10 加 tempField(p) 返回 0~1
//      温度——同心圆环 fbm + 锅心温度衰减。同心圆环作为反照率调制（亮
//      环 1.15×、暗环 0.85×），温度高时混入暗红（>0.7→红热），温区
//      混入灶圈蓝光（0.4~0.7→蓝黑）。这是"锅在受热"的视觉证据——
//      没有温度场的锅面就是冷铁皮。
//   3. **水珠沸腾翻滚**：v9 的 HEAT_JITTER 是均匀的 ±6% 半径脉动，看起来
//      像液滴在"颤"，但不像"沸"。v10 加 boilK（每滴独立沸腾度，随生命
//      周期慢变）：wob 振幅 ×(1+boilK*0.5) 让形状更剧烈变形，半径
//      ×(1+boilK*0.12*sin(...)) 让高度场大幅脉动，接触阴影同步
//      抖动——液滴"内部在翻腾"，不再只是抖。
//   4. **接触处沸腾暗环 + 气泡**：v9 的焦散是亮环（液滴把光聚到锅面）。
//      参考图接触处是**暗环**（沸腾区，温度极高 + 碳渍 + 气泡群），实
//      拍炒锅里沸腾区颜色比周围暗（不是更亮）。v10 用 tempField 在接触
//      处的局部高温驱动暗化，再叠一层高频小气泡（细密暗点群）。
//   5. **飞溅粒子（简化实现）**：参考图大液滴濒死时炸出小液滴。v10 在
//      濒死期（lifeK>0.9）让液滴形状极不规则（wob 振幅 ×3 接近爆裂态），
//      并从液滴中心沿速度方向射出 2-3 道短亮线（视觉上的"飞溅"轨迹）。
//      真正的粒子系统需多层渲染 / 几何 shader，单 pass fragment 内
//      难做全套；这种"溅射条纹"是单 pass 下的高性价比近似。
//   6. **锅口白烟增强**：v9 蒸汽只有 1 层（STEAM_ALPHA=0.38）。v10 加
//      接触处局部白烟（每颗水珠周围小范围浓白雾，活跃时更浓）——
//      沸腾的水珠不只是冒大蒸汽，接触处先冒一小团白烟。两个蒸汽层
//      叠加 = 锅口弥漫的白雾。
//
// 不变量：BOTTOM_NEAR / BOTTOM_FAR / innerWallColor / 蒸汽开口面源
// 都不动（回归测试已锁）；真·凹底几何核心（v8）保留。
//
// v9 相对 v8.1 的物理增强（用户要求四件事：锅底是球形曲面不是平面；
// 水珠是不规则类球体不是标准半球；水珠受热上下震动 + 运动速度随机；
// 材质更贴近真实受热水珠）：
//   1. **锅底真球冠**：v8 的法线是线性的（−p·BOWL_TILT = 抛物面近似，
//      曲率均匀铺开，视觉上锅心仍像平面）。v9 用解析球冠法线
//      n ∝ (p / √(R²−r²), 1)——曲率**集中在锅沿**：锅心几乎平（反射
//      天花板），越靠底缘法线越陡（扫过整个环境），光滑球形面的观感
//      来自这种"锅心平、锅沿快速弯下去"的曲率分布。BRUSH_PERTURB
//      0.085→0.060（拉丝扰动减轻，球面更光滑）。
//   2. **水珠不规则类球体**：d_eff 的角向谐波从 3 项加到 5 项（2/3/4/5/7
//      阶混合），并叠一道**定向拉伸**（受热不均 → 液滴沿受热最弱方向
//      拉长成泪滴形）——标准半球是球对称的，真实蒸气垫液滴是不对称的
//      变形球体。
//   3. **受热震动**：蒸气垫把液滴顶起→落下，全场叠加小幅高度振荡
//      （HEAT_JITTER=±6% 半径脉动，两个不可通约频率），影子/轮廓/焦散
//      同步搏动——不是只有濒死期才跳，整个生命周期都在微颤。
//   4. **速度随机化**：每滴运动速度不再是固定公式，而是乘一个受热强度
//      因子 heatK = vn 慢漂（每滴的热斑随时间漂移，速度在 0.72×~1.35×
//      之间随机波动）——受热不均 → 有的珠急转、有的珠缓移。
//   5. **材质增强**：① 水珠补漫反射项（天空光 diffuse，不纯镜面）；
//      ② 灯泡泛光高光（pow 60 中锐）与窗光针尖（pow 320）双层高光；
//      ③ 薄缘透光（接触线外缘一圈背景透亮，与 RIM_DARK 压暗的内缘
//      形成"暗边 + 亮线"的真实液滴边缘）。
//   不变量：BOTTOM_NEAR / BOTTOM_FAR / innerWallColor / 蒸汽开口面源
//   都不动（回归测试已锁）；暗锅基调、水珠"暗底玻璃体"方向不动。
//
// v8.1 相对 v8 的观感微调（v8 的结构性修复都已 commit；本轮纯粹把"看进
// 锅里"的视觉权重再放大一点——v8 的剖面验证发现锅心 / 内壁亮度差偏小，
// "凹下去"的纵深证据不够厚）：
//   1. 锅心聚油压暗 BOWL_DARK 0.22→0.30：球冠反射让锅心反射天花板（亮），
//      但真实黑锅的聚油/碳渍层把这份亮反射压下去——v8 这部分压暗幅度不
//      够，锅心-内壁的明暗差不足以让眼睛读出"凹"。
//   2. 内壁环带加宽 WALL_W 0.24→0.28：远侧内壁"映天花板"的亮区是深锅
//      俯视透视最强的证据；环带变宽后这片亮区更显著，深锅的"看进去"
//      观感更扎实。
//   不变量：BOTTOM_NEAR / BOTTOM_FAR 不动（v8 真·凹底几何核心）；水珠材
//   质、蒸汽位置、暗锅基调都不动——回归测试已锁。
//
// v8 相对 v7 的返工（用户反馈三条：锅还是平底锅——对，v7 的"凹"只做了
// 法线倾斜，俯视图里锅底仍铺满整个椭圆 = 还是平底锅；水珠不像现实；
// 蒸汽位置不对）：
//   1. 真·凹底构图：v7 的病根是"锅底 = 整个椭圆，内壁画在椭圆外"。
//      v8 把**底缘收进椭圆内部**——可见锅底是一个比锅口小的区域
//      （远侧底缘收到 pr≈0.58、近侧 0.92），底缘与沿口之间是**可见的
//      内壁环带**（远侧宽亮映天花板、近侧窄暗）。这才是深锅俯视透视：
//      一眼看出"看进锅里"而不是"看平底锅"。
//   2. 暗锅 + 水珠材质收敛：锅面再压暗（漫反射 0.28→0.18、反照率
//      0.20→0.14、回火色 0.22→0.18）——真实黑锅是暗底，水珠是暗底上
//      的玻璃体，不是亮钢面上的水银球；水珠减亮（LENS 0.85→0.70、
//      through 1.55→1.35、GLINT 2.6→2.0）压住"液态金属"感，改成
//      "暗背景上的透明透镜"。
//   3. 蒸汽从**锅口开口面**升起（v7 从远侧沿一条线冒 = 位置不对）：
//      源强 = 锅口椭圆内部（锅心最强、沿口衰减），从锅口高度起上升、
//      越高越散越淡，窗侧逆光微亮。
//
// v7 相对 v6 的返工（用户反馈两条：锅形错了——是凹底锅不是平底锅；
// 水珠材质与真实差距大）：
//   1. 凹底锅几何：锅底法线从"平面 + 拉丝扰动"改为**球冠法线**（随半径
//      向锅心倾斜 BOWL_TILT）——反射环境从锅心的亮天花板扫到中环的低处
//      暗墙面，径向明暗梯度就是"凹下去"的深度线索；锅心聚油处再压暗。
//      内壁环带 0.18→0.24 且**远侧更高**（深锅俯视透视：远侧内壁看得见
//      一大圈，近侧只剩沿口）。水珠行为跟着改：活动范围收拢到中央 62%
//      （滑向最低点），并绕锅心缓慢盘旋（凹面上蒸气垫液滴的真实轨道）。
//   2. 水珠材质"湿润感"：每颗水珠补一枚**锐利窗光高光点**（pow 320——
//      真照片里每颗水珠都有一个针尖亮斑，缺了它就是哑光玻璃珠）；折射
//      体边缘压暗 30% 勾出轮廓（接触线全反射 + 阴影）；濒死期半径
//      ±28% 脉动（蒸气垫破裂前的弹跳）；内部聚光/焦点增益上调。
//
// v6 相对 v5 的"真实感"返工（把"插画"里的三处硬伤改对）：
//   1. 液滴"去卡通化"：旧 15 颗、最大半径 0.30（= 锅径 30%），是一锅大珠子。
//      v6 扩到 36 颗（30 主滴 + 6 卫星）、半径压到 0.018~0.075（锅径 1~4%），
//      用帕累托分布铺成真实莱顿弗罗斯特那种"一锅密密麻麻的小珠"。
//   2. 明暗对比：锅面漫反射 0.42→0.28、镜面 0.62→0.72、反照率 0.38→0.20——
//      真实的黑锅是"暗底 + 强高光"，不是均匀发灰的钢面。
//   3. 小珠更"活"：速度下限从 0.05 收到 0.018，小液滴在蒸气垫上滑得更快
//      （真实里越小的珠越躁动）。
//
// v5 相对 v4 的真实感补齐（两处，都来自莱顿弗罗斯特液滴的实拍特征）：
//   1. 接触线薄膜干涉：液滴被蒸气垫托起，底部与锅面之间是一层微米级
//      气隙——光在气隙上下两界面反射干涉。接触线处气隙最薄、向内逐渐
//      变厚 → 经典的牛顿环虹彩。实拍里每颗大液滴脚下都有一圈彩虹，
//      这是"照片级"与"CG"的分水岭，v4 完全缺失。
//   2. 焦散环：液滴是一枚悬空透镜，把上方窗光/灯光聚焦到锅面，光侧
//      接触线外缘因此多出一圈亮边（是聚焦的硬边，不是泛光）。
//
// v4 相对 v3 的三处结构返工：
//   1. 椭圆透视锅（v3"看不出是锅内侧"的病根）：v3 锅半径 0.44 定义在
//      宽高比修正坐标里——竖屏 x 可视半宽只有约 0.23，锅沿左右溢出屏幕，
//      锅口根本看不见，只剩中央一块圆面+回火色环 = 看起来像锅外底。
//      v4 锅是**椭圆**：宽按屏宽 84% 自适应（RX=0.42×aspect），y 压扁
//      0.75（俯视透视），并渲染**内壁环带**：近侧内壁（画面下方）迎光
//      反射天花板、远侧背光渐暗、沿口卷边高光弧——一眼看进锅里的构图。
//      水珠场在锅局部坐标（单位圆）计算：屏幕上呈椭圆轨迹与椭圆水珠，
//      与俯视透视物理一致。
//   2. 明亮厨房（v3"水珠黑"的另一半病根）：v3 环境光是深夜厨房（房间
//      上半球 0.045），锅面漫反射底子 ~0.03——水珠透过去必然黑。
//      v4 白天厨房：亮天花板 + 强窗 + 台面暖色，锅面均值亮度提 3~4 倍，
//      水珠内景（透射+聚光）显著亮于周围。
//   3. 蒸汽改为**锅口上方的上升气流**（v3 贴着锅面的亮雾 = "蒸汽沉在锅
//      底"）：竖长条纹理随时间上移、随高度展开消散、半透明白纱混合
//      （不是加亮），窗侧逆光亮化，bass 增浓。
//
// 保留 v3 已验证的物理：球冠高度场法线 h=√(1−1/F)、元球融合、d² 蒸发、
// 蒸气垫颤抖、濒死狂跳+边缘泡沫化、角向谐波轮廓、折射/反射能量混合、
// 背光新月、焦点亮斑、回火色静态径向环带（中心蓝→外缘黄）。
//
// 公共函数（hash/vn/fbm/filmic/dither/…）由工具链从 common.glsl 注入，
// 不要在本文件重复定义。

// ---- 环境光（白天厨房：锅与水珠共用同一组光）--------------------------------
const vec3 WIN_DIR = vec3(-0.486, 0.549, 0.684);   // 冷白窗（已归一）
const vec3 BULB_DIR = vec3(0.503, 0.302, 0.809);   // 暖灯泡（已归一）
const vec3 WIN_COLOR = vec3(1.05, 1.12, 1.30);
const vec3 BULB_COLOR = vec3(1.30, 0.98, 0.62);
const vec3 ROOM_SKY = vec3(0.50, 0.52, 0.56);      // 亮天花板漫射
const vec3 ROOM_FLOOR = vec3(0.14, 0.11, 0.09);    // 台面暖木色
const float WIN_SHARP = 16.0;      // 窗立体角（宽窗：更多水珠挂到窗形高光）
const float BULB_SHARP = 90.0;

// ---- 锅（椭圆透视 × 凹底球冠 × 收进的内壁环带）------------------------------
const float PAN_FILL = 0.42;       // 锅半宽 = FILL × aspect（锅占屏宽 84%）
// ---- v15 真 3D 锅几何（光线-球面求交，替代伪 2D 椭圆构图）----------------
// v8~v14 的 p 空间是伪 3D：把"锅口椭圆的中心"当成了锅心（PAN_CENTER=(
// 0,-0.03)）。真实球冠 + 正交斜视投影下，锅心必须落在锅口椭圆中心**下方**
//   0.157（q 单位，= 锅深 D × sinα / 尺度）；锅口椭圆中心才在上方。
// 这个错位让"锅底"被人为抬高，远侧内壁环带被撑成锅半径的 42%（BOTTOM_FAR
// =0.58 是拍脑袋常量），再被 innerWallColor 涂成比锅底还亮的均匀灰
// （0.24~0.34 vs 锅底 0.227）——于是一大片连续亮区从假底缘线铺到锅口，
// 这就是用户看到的"锅里装了 1/3 高的水"。
// 现在几何全部由真实球面求交给出：锅 = 球冠（锅口半径 1、锅深 PAN_DEPTH）、
// 相机正交斜视（俯视角 α，cosα = TILT_COS）。内壁宽度、底缘位置、法线、
// 水滴的透视缩短全部是算出来的，不再有可调的"假底缘"。
const float PAN_DEPTH = 0.50;      // 锅深 / 锅口半径（真实炒锅 ≈0.5：
                                   //   口径 30cm、深 9cm → 9/15 = 0.6，取 0.5）
const float TILT_COS = 0.75;       // 俯视角 cosα（= 原 PAN_SQUASH；α≈41°）
const float TILT_SIN = 0.6614;     // sinα = √(1−cos²α)
// 球冠半径（锅口半径归一化为 1）：D = Rs − √(Rs²−1) ⟹ Rs = (1+D²)/(2D)
const float PAN_SPHERE_R = (1.0 + PAN_DEPTH * PAN_DEPTH) / (2.0 * PAN_DEPTH);
                                   //   球面曲率 = 1/R：1.30 时锅心曲率太小（视觉
                                   //   "平"——用户反馈"锅最底部为什么是平的"）。
                                   //   1.10 让锅心明显弯曲（深炒锅），底缘处法线
                                   //   ~57°——真正的"球体锅身"观感。
const float BOWL_DARK = 0.38;      // 锅心聚油/自阴影压暗（v11 0.30→0.38：
                                   //   收进椭圆内部一大圈
const float WALL_W = 0.32;         // 内壁环带基准宽度（v11 0.28→0.32：球面
                                   //   锅身 + 更宽内壁 = 深炒锅的"看进去"
                                   //   透视更扎实）
const float OUTER_W = 0.10;        // 外壁环带宽度

                                   //   1=可爬到锅口沿）。0.55 让受热乱窜的
                                   //   珠能贴着内侧壁滑上一截——"贴壁 3D"的
                                   //   主要视觉证据
// ---- v16 真实莱顿弗罗斯特物理（替代拍脑袋的经验系数）---------------------
// 【毛细长度 / Bond number】液滴形态由 Bo = ρgR²/σ = (R/l_c)² 决定：
//   l_c = √(σ/(ρg)) —— 水的毛细长度 ≈ 2.7mm。锅口半径 150mm（30cm 口径）
//   ⟹ l_c ≈ 0.018（锅局部单位，锅口半径归一化为 1）
//   · R < l_c ：表面张力主导 → 近似球形（R=1mm 的小珠就是一颗小球）
//   · R >> l_c：重力主导 → 摊成**厚度恒定**的扁饼 h ≈ 2·l_c（与体积无关！）
//     这是莱顿弗罗斯特大液滴的真实形态，不是半球。R=11mm 的珠厚度只有
//     5.4mm，h/R ≈ 0.49 —— 看起来就是贴着锅面的一摊，不是立起来的球。
//   ⟹ hDome 上限 = min(1, 2·l_c / R)（1 = 半球，<1 = 摊平的饼）
// 【Rayleigh 液滴振荡】n=2 基模频率 f = (1/2π)·√(σ/(ρR³))·√(n(n-1)(n+2))
//   ⟹ f ∝ R^-3/2：小珠颤得快（~20Hz）、大珠颤得慢（~1.6Hz）。原来用的
//   "9 + 7·h2" 与半径无关，大珠小珠颤得一样快，是错的。
const float CAPILLARY = 0.018;     // 毛细长度 l_c（锅局部单位；= 2.7mm/150mm）
const float RAYLEIGH_K = 0.033;    // Rayleigh 振荡系数（f = K·R^-3/2 Hz）
const float DROP_FLAT = 0.62;      // 水珠扁平度（v14：锅底只有水珠、没有"那么
                                   //   → 略大；远侧内壁的珠离相机远 → 略小
                                   //   （近大远小是最强的 3D 深度线索）

// ---- v15 真 3D 水滴运动（球面极角 θ + 重力）--------------------------------
// 用户：水滴不可能长时间维持在锅内侧的同一高度，重力会让它很快下来。
// 所以极角 θ 必须是**摆动**而非自由游走：θ = θ_max·|sin(ωt+φ)|^p
//   · θ=0（锅心）时 dθ/dt 最大 → 穿过锅心一掠而过
//   · θ=θ_max 时 dθ/dt=0 → 在最高点折返（滑梯转折点，符合能量守恒）
//   · p>1 让水滴更多时间待在锅底（势能低处）——"重力让它待在下面"
// θ_max 由"最高 ≈1/3 锅高"定：z = Rs(1−cos θ) = D/3 = 0.167
//   ⟹ cos θ = 1 − 0.167/1.25 = 0.867 ⟹ θ_max ≈ 0.524 rad (30°)
const float DROP_THETA_MAX = 0.524;
const float GRAV_P = 1.6;          // 重力偏置指数（1=纯摆动，2=更多时间在锅底）
const float PAN_DIFF = 0.42;       // 钢面漫反射占比（v13 0.55→0.42：让位给镜面
                                   //   ——黑碳钢仍哑光为主，但要给球冠法线的镜面
                                   //   反射留出可见度）
const float PAN_SPEC = 0.48;       // 钢面镜面强度（v13 0.30→0.48：锅底"看起来
                                   //   平"的根因——球面感来自镜面反射 refl 随半径
                                   //   的渐变（锅心反射天花板亮、锅沿反射暗墙），
                                   //   PAN_SPEC 太弱时这个渐变被漫反射淹没，锅底
                                   //   读作"均匀暗平面"。0.48 让径向明暗渐变显现，
                                   //   又不至于变成亮金属）
const float BRUSH_PERTURB = 0.045; // 拉丝法线扰动（v10 0.060→0.045：黑碳钢
                                   //   比拉丝不锈钢更光滑，只有极轻的拉丝质感）
const float ALBEDO_BASE = 0.07;     // v10 锅底反照率基色（0.14→0.07：黑碳钢
                                   //   比不锈钢暗 1 个 stops）
const float HEAT_TINT = 0.55;       // 锅心红热混入强度（温度 > 0.7 时往暗红
                                   //   偏——参考图锅心是暗红热区）
const float FLAME_BLUE = 0.30;      // 灶圈蓝光混入强度（温度 0.4~0.7 区间，
                                   //   燃气反射的蓝色调）

// ---- 水滴群（锅局部坐标：单位圆 = 锅口内沿）---------------------------------
const int DROPLET_COUNT = 20;      // v12 性能：44→28→20（16 主滴 + 4 卫星）——
                                   //   field() 逐像素×逐滴循环是 GPU 最不擅长
                                   //   的负载（每滴十几个 hash/sin/atan），高分
                                   //   屏下再降一档保流畅，密度仍够
const float SATELLITE_FROM = 16.0;
const float R_MAIN_MIN = 0.014;    // 主滴半径区间（帕累托；真实液滴约锅径 1~4%）
const float R_MAIN_MAX = 0.075;
const float R_SAT_MIN = 0.010;
const float R_SAT_MAX = 0.030;
const float LIFE_BASE = 7.0;       // 寿命 = BASE + K·r²（d² 蒸发定律）
const float LIFE_K = 1150.0;
const float GROW_PHASE = 0.025;
const float GROW_MIN = 0.10;
const float FIELD_EPS = 1e-7;

// ---- 形状不规则（角向谐波 + 定向拉伸 = 不规则类球体）----------------------
const float WOB_SMALL_AMP = 0.12;   // v13 0.05→0.12：小珠也要看得出不规则
const float WOB_BIG_AMP = 0.40;     // v13 0.20→0.40：用户反馈"就是半球形"——
                                    //   ±20% 的 d_eff 扰动经元球高度场平均后肉眼
                                    //   仍读作圆；0.40 让轮廓明显凹凸
const float WOB_SIZE_LO = 0.060;
const float WOB_SIZE_HI = 0.240;
const float WOB_STRETCH = 0.70;     // 定向拉伸幅度（v13 0.40→0.70：明显泪滴形
                                    //   ——受热不均的真实液滴是拉长的，不是圆珠）
const float WOB_TURN = 0.32;       // 定向拉伸方向随受热慢转（弧度/滴生命周期）
const float WOB_BOIL_AMP = 0.85;   // v13 0.50→0.85：沸腾时形状剧烈翻腾变形
                                    //   （受热液滴是"活"的，不是静态不规则轮廓）

// ---- 锅底温度场（v16：删掉螺旋圆环）---------------------------------------
// v10~v15 的加热纹是三样东西叠出来的，用户看到的就是"一圈一圈的螺旋圆环，
// 一直在转"：
//   ① ring  = 0.5+0.5·sin(r·28)        —— 4.5 圈规则同心圆
//   ② swirl = sin(r·28·0.9 + ang·1.7)  —— 角度项把同心圆拧成螺旋
//   ③ ringK = sin(r·28 + ts·0.20)      —— 时间项让纹路一直游动
// 真实锅底：燃气火焰环只在锅底留**一圈**淡淡的灶痕（静态、不转），加热的
// 不均匀来自材质/油膜差异 → 用各向异性噪声表达，不用规则周期函数。
const float BURNER_R = 0.52;       // 燃气火焰环半径 / 锅口半径（家用灶火焰
                                   //   环直径 ≈ 8cm，锅口 30cm → 0.53）
const float BURNER_W = 0.22;       // 火焰环宽度（很宽的一圈灶痕，不是细环）
const float BURNER_K = 0.16;       // 灶痕强度（弱——被油膜/食物残渣盖住了）
const float HEAT_RING_K = 0.18;    // 静态使用痕迹的反照率调制深度（0.82~1.18）
const float HEAT_CENTER_BIAS = 0.35;// 锅心温度偏置（燃气集中在中心）
const float BUBBLE_DARKEN = 0.35;  // 接触处小气泡暗化强度（v16 0.55→0.35：
                                    //   变静态后是固定使用痕迹，不需要那么强）
const float BUBBLE_FREQ = 80.0;     // 接触处小气泡密度（每单位多少点）

// ---- 游走与濒死 ----------------------------------------------------------
const float PANIC_FROM = 0.93;
const float PANIC_BOOST = 5.0;
const float PANIC_HOP = 0.28;      // 濒死弹跳：半径脉动幅度（蒸气垫破裂前
                                   //   液滴在锅面上蹦跳——影子随场同步脉动）
const float SIZZLE_FROM = 0.90;
const float SIZZLE_AMP = 3.0;      // v7 加强（受热沸腾翻滚的观感）
const float HEAT_JITTER = 0.06;    // v9 受热震动：蒸气垫把液滴顶起→落下，
                                   //   半径 ±6% 高频脉动（比濒死弹跳小得多，
                                   //   整个生命周期持续）——水珠在热锅上
                                   //   永远是"跳着"的，不是静止的玻璃珠
const float HEAT_DRIFT = 11.0;     // 热斑漂移周期（秒；受热不均随时间的
                                   //   变化速率——每滴的热强度在漂移）
const float BOIL_KICK = 0.12;      // v10 沸腾半径脉动幅度（boilK × BOIL_KICK
                                   //   加到半径上——沸腾时液滴高度大幅脉动）
const float BOIL_RATE = 4.5;        // v10 沸腾主频率（Hz；每滴独立相位）
const float TREMBLE_AMP = 0.026;   // 锅局部坐标（约为屏幕坐标的 1/0.35）
const float TREMBLE_BASS = 1.6;
const float WANDER_NORM = 1.55;
const float SPEED_STRETCH = 0.22;
const float BOWL_GATHER = 0.85;    // 凹底收拢（v11 0.58→0.85：用户反馈水珠
                                   //   "只停在锅底最低处"太单调——真实物理里
                                   //   水珠被蒸气垫托着在球面上滑行/翻滚，活动
                                   //   范围大得多；只微弱地向锅心偏置即可）
const float DRIFT_AMP = 0.22;      // v11 随机漂移幅度：每滴一个慢变方向的
                                   //   "热流推挤"（wander 驱动）叠加到轨道上
                                   //   ——水珠被不同区域的热流推着乱窜，轨迹
                                   //   不再是一条规则绕圈
const float DRIFT_SCALE = 9.0;     // 漂移方向变化时标（秒/格；热流变化）

// ---- 场到表面的判定 -------------------------------------------------------
const float ISO_LO = 0.85;
const float ISO_HI = 1.15;
const float BEAT_BOIL = 0.05;
const float CONTACT_DARKEN = 0.50;
const float AO_DARKEN = 0.16;

// ---- 水珠材质 -------------------------------------------------------------
const float REFRACT_LEN = 0.34;    // 折射取样偏移（v11 0.28→0.34：透镜放大
                                   //   更强——水珠"实心"感，背景在滴内被
                                   //   放大更明显）
const float FOCUS_GAIN = 0.60;
const float LENS_GAIN = 0.70;      // 内部聚光（v8 收敛：压住"水银球"感——
                                   //   水珠是暗背景上的透明透镜，不是自发光球）
const float RIM_DARK = 0.30;       // 折射体边缘压暗（接触线全反射+阴影，勾轮廓）
const float GLINT_GAIN = 2.6;      // 窗光针尖高光（v11 2.0→2.6：水珠的"湿润
                                   //   感"几乎全在这枚高光上，更锐更亮）
const float SKY_GLINT = 0.45;      // v11 天光高光（pow 12 中锐的顶部泛光——
                                   //   湿润水面被天光整体点亮的那层光泽）
const float ABSORB_R = 0.8;
const float CRESCENT_GAIN = 0.70;
const float SPARKLE_GAIN = 1.8;
const float DROP_DIFF = 0.16;      // v11 水珠漫反射 0.10→0.16（微漫反射更亮，
                                   //   暗侧不死黑、整体更"实"）
const float BULB_GLOW = 0.50;      // v11 灯泡泛光高光 0.35→0.50（暖色泛光
                                   //   更明显——双层高光的第二枚）
const float RIM_LIGHT = 0.22;      // v9 薄缘透光：接触线外缘一圈背景透亮
                                   //   （薄处透光强），与 RIM_DARK 压暗的内缘
                                   //   形成"暗边 + 亮线"的真实液滴边缘
const float IRID_PATH_NM = 1500.0;  // 薄膜干涉光程差上限（nm；接触线 0 → 向内增）
const float IRID_GAIN = 0.55;       // 牛顿环虹彩强度（实拍里这是"标识性"特征，不能太弱）
const float IRID_FALLOFF = 22.0;    // 虹彩环带宽度（越小越贴接触线；太大扩散成色斑）
const float CAUSTIC_GAIN = 0.52;    // 接触线外缘焦散环强度

// ---- 蒸汽 / 收尾 ----------------------------------------------------------
const float STEAM_ALPHA = 0.55;    // 锅口蒸汽浓度（v10 0.38→0.55：参考图
                                   //   锅口弥漫着浓密白雾）
const float STEAM_RISE = 0.50;     // 上升速度（屏/秒，恒定）
const float STEAM_LOCAL_GAIN = 0.30; // v10 接触处白烟浓度（每颗水珠周围
                                   //   的小范围浓白雾——沸腾先冒小团再合并
                                   //   到锅口大蒸汽）
const float SPLASH_GAIN = 0.8;     // v10 飞溅条纹强度（濒死期从液滴中心
                                   //   沿速度方向射出的 2-3 道短亮线）
const float SEED_SPREAD = 173.0;

// 环境辐射：一组方向光照亮整个场景（锅面镜面、水珠反射、台面全用它）
vec3 envMap(vec3 r) {
    vec3 c = mix(ROOM_FLOOR, ROOM_SKY, smoothstep(-0.5, 0.45, r.z));
    float w = max(dot(r, WIN_DIR), 0.0);
    c += WIN_COLOR * (pow(w, WIN_SHARP) * 2.8 + pow(w, 6.0) * 0.55);
    float b = max(dot(r, BULB_DIR), 0.0);
    c += BULB_COLOR * (pow(b, BULB_SHARP) * 2.4 + pow(b, 10.0) * 0.22);
    return c;
}

// 薄膜干涉：两束反射光的光程差 optPath 逐波长相位不同 → 虹彩。
// 相位偏移 0.5 使零气隙处先破坏（暗），向内扫过整段可见光谱——与
// 牛顿环"接触点暗、向外彩虹"一致。
vec3 thinFilm(float optPath) {
    return 0.5 + 0.5 * cos(TAU * (optPath / vec3(645.0, 510.0, 440.0) + 0.5));
}

// ---- 真 3D：屏幕 → 锅面（光线-球面求交）----------------------------------
// 输入 s：屏幕坐标，单位 = 锅口半径（1.0 = 锅口），原点 = 锅心的投影。
// 锅面 = 球面 x²+y²+(z−Rs)² = Rs² 上 z ≤ D 的部分（球心 (0,0,Rs)，锅心在原点）。
// 正交斜视投影：sy = y·cosα + z·sinα，sx = x。
// 把 y = (sy − z·sinα)/cosα 代入球面，整理得 z 的二次方程：
//     z² − 2(sy·sinα + Rs·cos²α)·z + (sx²·cos²α + sy²) = 0
// 可见性取 **z ≤ D 的最大根**：远侧大根落在球的上半部（z>D，不存在）→ 取
// 小根；近侧大根是锅沿（z=D）→ 取大根，内壁被锅沿遮住。这正是俯视深锅该
// 有的样子（近侧内壁压成极窄一条，远侧内壁舒展）。
bool panHit(vec2 s, out vec3 P, out vec3 N) {
    float Rs = PAN_SPHERE_R;
    float D = PAN_DEPTH;
    float ca = TILT_COS, sa = TILT_SIN;
    float b = s.y * sa + Rs * ca * ca;
    float c = s.x * s.x * ca * ca + s.y * s.y;
    float disc = b * b - c;
    P = vec3(s.x, 0.0, 0.0);
    N = vec3(0.0, 0.0, 1.0);
    if (disc < 0.0) return false;              // 视线不与锅面相交
    float sq = sqrt(disc);
    float zHi = b + sq;                        // 大根（离相机近的一侧）
    float zLo = b - sq;                        // 小根
    float z = (zHi <= D) ? zHi : zLo;          // 取锅口平面以下的最大根
    if (z > D || z < -1e-3) return false;
    float y = (s.y - z * sa) / ca;
    P = vec3(s.x, y, z);
    // 法线指向**锅内表面**（朝上）。注意：球面外法线 normalize(P − 球心)
    // 指向下方（锅面是球的下半部，球心在上方 Rs 处），取反才是我们看到
    // 的那一面——锅心处应为 (0,0,1)，写成外法线会让锅渲染成凸面、光照全反
    N = normalize(vec3(-P.x, -P.y, Rs - z));
    return true;
}

// 球面点（极角 θ、方位 φ）→ 3D 坐标。θ=0 是锅心，θ=θ_rim 是锅口
vec3 bowlPoint(float th, float ph) {
    float Rs = PAN_SPHERE_R;
    float st = sin(th), ct = cos(th);
    return vec3(Rs * st * cos(ph), Rs * st * sin(ph), Rs * (1.0 - ct));
}

// 3D 点 → 屏幕坐标（正交斜视；单位同 panHit 的输入 s）
vec2 bowlProject(vec3 Pw) {
    return vec2(Pw.x, Pw.y * TILT_COS + Pw.z * TILT_SIN);
}

// ---- v17 水珠状态预通道 -----------------------------------------------------
// 每颗水珠的完整状态只依赖 (索引, t, seed, uBass)——是每帧常量，却曾在
// field() 里被逐像素重复计算（20 滴 × 十余次 hash/sin/vn/wander，本场景
// 卡顿主因）。三条路径共用同一 dropState()，行为一致：
//   uStateMode=1：写出模式——以 20×PAN_STATE_ROWS 小视口渲染，每格写一个
//     vec4 状态槽到 RGBA16F 纹理（C++ 侧每帧主 pass 之前调起一次）；
//   uStateMode=2：主 pass 用 texelFetch 取回状态（常规路径）；
//   PAN_NO_STATE_TEX：设备无浮点 FBO 时的编译期回退，逐像素重算。
// uStateMode/uState 不在注入头 uniform 名单内，gen_shader_header.py 与
// glslPatch.ts 均按名单置空，本文件里的声明会原样保留。
uniform float uStateMode;
#ifndef PAN_NO_STATE_TEX
uniform sampler2D uState;
const int PAN_STATE_ROWS = 4;
#endif

struct PanDrop {
    vec2 pos;
    float rr;
    float rad;
    vec2 vh;
    float k;
    float fores;
    float wamp;
    float phase;
    float dirA;
    float sizzleW;
    float h1t;
    float h4t;
    float h3t;
};

// 单颗水珠的本帧状态（计算式与 v16 逐像素路径逐句等价，仅改为打包输出；
// 死亡滴 rr=0，调用方以 FIELD_EPS 阈值跳过）。
PanDrop dropState(float fi, float ts, float sd) {
    PanDrop o;
    o.rr = 0.0; o.rad = 0.0; o.k = 0.0; o.fores = 1.0;
    o.wamp = 0.0; o.phase = 0.0; o.dirA = 0.0; o.sizzleW = 0.0;
    o.h1t = 0.0; o.h4t = 0.0; o.h3t = 0.0;
    o.pos = vec2(0.0); o.vh = vec2(1.0, 0.0);
    float small = step(SATELLITE_FROM, fi);
    float h1 = hash11(fi * 7.13 + sd);
    float h2 = hash11(fi * 3.71 + sd + 11.0);
    float h3 = hash11(fi * 5.39 + sd + 23.0);
    float h4 = hash11(fi * 9.17 + sd + 37.0);
    float r0 = mix(mix(R_MAIN_MIN, R_MAIN_MAX, pow(h3, 2.6)),
        mix(R_SAT_MIN, R_SAT_MAX, pow(h3, 1.5)), small);
    float P = (LIFE_BASE + LIFE_K * r0 * r0) * (0.70 + 0.60 * h1);
    float age = mod(ts + h2 * P, P);
    float lifeK = age / P;
    float grow = mix(GROW_MIN, 1.0, smoothstep(0.0, GROW_PHASE, lifeK));
    float rr = r0 * r0 * grow * max(1.0 - lifeK, 0.0);
    // 沸腾度（v10）：每滴独立沸腾相位——蒸气速在液滴底部生成气泡，
    // 气泡破裂让液滴"内部在翻腾"。沸腾度同时调制半径脉动幅度和
    // 形状变形振幅，活跃期（lifeK 0.5~0.9）最强，濒死期还伴随
    // 形状极不规则（接近爆裂态）。两个频率叠加避免节拍化
    float boilK = 0.5 + 0.5 * sin(age * BOIL_RATE + fi * 5.7)
        * (0.5 + 0.5 * sin(age * (BOIL_RATE * 0.43) + fi * 1.9));
    // 受热震动（v16 Rayleigh 液滴振荡）：蒸气垫把液滴顶起→落下。
    // n=2 基模 f = (1/2π)·√(σ/(ρR³))·√8 ⟹ f ∝ R^-3/2——小珠颤得快
    // （~20Hz）、大珠颤得慢（~1.6Hz）。v9 用的"9+7·h2"与半径无关，
    // 大珠小珠颤得一样快，不符合真实物理。
    float oscF = clamp(RAYLEIGH_K / pow(max(r0, 6e-3), 1.5), 1.2, 30.0);
    float heatHop = 1.0 + HEAT_JITTER * sin(age * oscF + fi * 3.7)
        * (0.5 + 0.5 * sin(age * oscF * 0.31 + fi * 1.9));
    // 沸腾半径脉动（v10）：boilK × BOIL_KICK 调制——沸腾时液滴高度
    // 大幅脉动（液滴在"咕嘟咕嘟"地翻）
    float boilKick = 1.0 + BOIL_KICK * boilK
        * sin(age * (BOIL_RATE * 2.7) + fi * 4.3);
    rr *= heatHop * boilKick;
    // 濒死弹跳：蒸气垫破裂前液滴在锅面上蹦跳（半径脉动 → 接触阴影
    // 与轮廓同步搏动；系数最低 0.72，不会反号）
    float hopK = smoothstep(PANIC_FROM, 1.0, lifeK);
    rr *= 1.0 + PANIC_HOP * hopK * sin(age * 36.0 + fi * 7.0);
    if (rr < FIELD_EPS) return o;
    float rad = sqrt(rr);
    // 受热强度（v9）：每滴的热斑随时间慢漂——受热不均 → 运动速度
    // 不是固定公式，而在 0.72×~1.35× 之间随机波动（急转的珠会缓下
    // 来、缓移的珠会窜出去，像真实锅里被不同区域热流推着走）
    float heatK = 0.28 + 0.72 * vn(vec2(age / HEAT_DRIFT + fi * 2.7,
        sd * 0.011 + h1 * 4.0));
    float sp = (0.9 + 0.5 * h4) * pow(0.12 / max(r0, 0.018), 0.35)
        * mix(0.72, 1.35, heatK);
    sp = clamp(sp, 0.6, 3.2);
    float panic = 1.0 + PANIC_BOOST * smoothstep(PANIC_FROM, 1.0, lifeK);
    float w1 = 1.35 * h4 * sp;
    float w2 = 3.10 * h1 * sp;
    float w3 = 1.15 * h2 * sp;
    float w4 = 2.70 * h3 * sp;
    float p1 = fi * 2.1;
    float p2 = fi * 5.3;
    float p3 = fi * 3.7;
    float p4 = fi * 1.9;
    vec2 pos = vec2(
        sin(age * w1 + p1) + 0.55 * sin(age * w2 + p2),
        cos(age * w3 + p3) + 0.55 * cos(age * w4 + p4));
    vec2 vel = vec2(
        w1 * cos(age * w1 + p1) + 0.55 * w2 * cos(age * w2 + p2),
        -w3 * sin(age * w3 + p3) - 0.55 * w4 * sin(age * w4 + p4));
    // 凹底行为：活动范围只微弱向锅心偏置（v11 0.85——球面上水珠被
    // 蒸气垫托着四处滑行，重力只是弱引导，不会钉死在锅心）
    float range = (1.0 - rad - 0.05) * BOWL_GATHER;
    pos *= range / WANDER_NORM;
    vel *= range / WANDER_NORM;
    // v11 随机漂移（热流推挤）：每滴一个慢变方向的随机力叠加到轨道
    // 上——真实锅里水珠被不同区域的热流/气流推着乱窜，轨迹不是规则
    // 绕圈。wander 混沌驱动方向（每 DRIFT_SCALE 秒换向），幅度随受热
    // 强度波动
    float dr = DRIFT_AMP * (0.7 + 0.6 * heatK);
    float driftX = wanderBi(age / DRIFT_SCALE + fi * 1.7, 1.0,
        sd * 0.7 + h2 * 3.0);
    float driftY = wanderBi(age / DRIFT_SCALE + fi * 3.1, 1.0,
        sd * 1.3 + h1 * 5.0);
    // ---- v15 真 3D 球面运动（替代 v11 的绕心盘旋 + v14 的伪球面）----
    // ① **删掉绕心盘旋**：ORBIT_RATE 让每滴以恒定角速度绕锅心转，珠群
    //    一旦靠近就融合成一团跟着转 = 用户看到的"螺旋圆一直在转"。
    //    真实锅里没有这种整体环流。
    // ② 热流推挤改为驱动**球面方位角 φ**（左右乱窜）+ 小幅极角扰动
    //    （上下起伏）——上上下下左左右右，不是绕圈。
    float phi = atan(pos.y, pos.x)
        + driftX * dr * 5.0                       // 左右：绕着锅心换方位
        + 0.55 * sin(age * (w1 * 0.7 + 0.4) + p2); // 持续横向游走
    // ③ 极角 θ = 重力滑梯（GRAV_P 让水滴更多时间待在锅底）
    float wR = 0.55 + 0.75 * h3 * mix(0.72, 1.35, heatK);
    float th = DROP_THETA_MAX
        // pow(x,y) 在 x=0 时是 GLSL 未定义行为（SwiftShader 返回 NaN 会
        // 让整帧崩掉），必须夹一个下限
        * pow(max(abs(sin(age * wR + fi * 2.7)), 1e-4), GRAV_P);
    th += driftY * dr * 0.55;                     // 上下：热流顶起来的起伏
    th = clamp(th, 0.0, DROP_THETA_MAX);
    vec3 Pd = bowlPoint(th, phi);
    pos = bowlProject(Pd);
    // ④ 透视缩短：贴在球面上的水滴沿屏幕 y 被斜视投影压缩（真 3D 的
    //    自然结果，不是 v14 那套拍脑袋的 PARALLAX 常数）
    vec3 Nw = normalize(vec3(-Pd.x, -Pd.y, PAN_SPHERE_R - Pd.z));  // 锅内表面法线（朝上）
    float fores = clamp(dot(Nw, vec3(0.0, -TILT_SIN, TILT_COS)), 0.35, 1.0);
    vel = vec2(vel.x, vel.y * fores);
    vec2 trem = TREMBLE_AMP * panic * (1.0 + TREMBLE_BASS * uBass)
        * vec2(sin(age * 23.0 + fi * 9.0), cos(age * 29.0 + fi * 4.0));
    pos += trem;
    // 等值面不越过锅口内沿（真实几何：水平半径 ≤ 1）
    float maxR = 1.0 - 2.3 * rad - 0.05;
    if (maxR <= 0.0) {
        return o;   // 越界滴：贡献为 0（等价 v16 的 continue）
    }
    float pl = length(pos);
    if (pl > maxR) {
        pos *= maxR / pl;
    }
    // ---- 以下与像素无关（v16 在 field() 循环里逐像素重算的部分）----
    float spd = length(vel);
    float k = clamp(spd * SPEED_STRETCH, 0.0, 0.6);
    vec2 vh = vel / max(spd, 1e-4);
    float wsize = smoothstep(WOB_SIZE_LO, WOB_SIZE_HI, rad);
    // 沸腾度调制 wob 振幅（v10）：沸腾时形状剧烈变形——大珠在
    // lifeK 中段 (0.5~0.9) 变形振幅 ×2+，濒死期 (lifeK>0.9) ×3 接近
    // 爆裂态（飞溅条纹的视觉基础）
    float boilShape = 1.0 + boilK * WOB_BOIL_AMP
        * (0.5 + 1.5 * smoothstep(0.85, 0.99, lifeK));
    float wamp = mix(WOB_SMALL_AMP, WOB_BIG_AMP, wsize) * boilShape;
    float wrate = (0.6 + 0.9 * h2) * mix(1.8, 0.7, wsize)
        * (1.0 + 0.6 * boilK * smoothstep(0.85, 0.99, lifeK));
    // v12 性能：sizzle 噪声从 vn(p*150)（per-pixel 4 次 hash）改为
    // hash11（每滴 1 次，不依赖像素坐标）——濒死期液滴边缘沸腾抖动的
    // 观感等价
    float sizzle = smoothstep(SIZZLE_FROM, 1.0, lifeK);
    float sizzleW = sizzle * (hash11(age * 7.0 + fi * 3.0 + sd * 0.01) - 0.5)
        * SIZZLE_AMP;
    o.pos = pos; o.rr = rr; o.rad = rad;
    o.vh = vh; o.k = k; o.fores = fores;
    o.wamp = wamp; o.phase = age * wrate; o.dirA = h2 * TAU + age * (WOB_TURN * 0.5 + 0.12 * heatK);
    o.sizzleW = sizzleW;
    o.h1t = h1 * TAU; o.h4t = h4 * TAU; o.h3t = h3 * TAU;
    return o;
}

#ifndef PAN_NO_STATE_TEX
// 状态纹理读取：每滴 4 个 vec4 槽（slot0 pos/rr/rad，slot1 vh/k/fores，
// slot2 wamp/phase/dirA/sizzleW，slot3 谐波相位）。RGBA16F 的 10 位尾数
// 对位置（≈0.1px）与相位（≈0.03rad）的量化误差均在感知阈值之下。
// texelFetch 为 ES3 内建（两条管线均以 300 es 编译），无过滤无导数，
// 可在分支内安全使用。
PanDrop fetchDrop(int i) {
    PanDrop o;
    vec4 s0 = texelFetch(uState, ivec2(i, 0), 0);
    vec4 s1 = texelFetch(uState, ivec2(i, 1), 0);
    vec4 s2 = texelFetch(uState, ivec2(i, 2), 0);
    vec4 s3 = texelFetch(uState, ivec2(i, 3), 0);
    o.pos = s0.xy; o.rr = s0.z; o.rad = s0.w;
    o.vh = s1.xy; o.k = s1.z; o.fores = s1.w;
    o.wamp = s2.x; o.phase = s2.y; o.dirA = s2.z; o.sizzleW = s2.w;
    o.h1t = s3.x; o.h4t = s3.y; o.h3t = s3.z;
    return o;
}
#endif

// 水滴元球场（锅局部单位圆坐标）：F = Σ r²/d_eff²，g = ∇F。
// d_eff 含运动方向拉伸 + 角向谐波轮廓（不规则类球体）+ 受热震动 + 濒死泡沫化。
// v17：每滴状态取自状态纹理（或回退路径的 dropState），循环体只剩
// 像素相关的距离/轮廓/累积。
float field(vec2 p, float ts, float sd, out vec2 g, out float dropRad) {
    g = vec2(0.0);
    float F = 0.0;
    // v16：主导水滴半径（按 w 加权的场贡献半径）——供毛细长度扁平化用。
    // 大液滴（R >> l_c）摊成恒定厚度的扁饼，小液滴保持球形，需要知道
    // "当前像素主要属于哪一滴、它多大"
    float wRadSum = 0.0;
    float wSum = 0.0;
    for (int i = 0; i < DROPLET_COUNT; i++) {
        float fi = float(i);
#ifdef PAN_NO_STATE_TEX
        PanDrop st = dropState(fi, ts, sd);
#else
        PanDrop st = fetchDrop(i);
#endif
        if (st.rr < FIELD_EPS) continue;
        // 各向异性距离：y 方向除以 fores → 等值面在屏幕上是 x 半径 r、
        // y 半径 r×fores 的椭圆（贴壁的水滴被斜视压扁，真 3D 的必然结果）
        vec2 d = vec2(p.x - st.pos.x, (p.y - st.pos.y) / st.fores);
        float dpar = dot(d, st.vh) * (1.0 - 0.24 * st.k);
        float dperp = dot(d, vec2(-st.vh.y, st.vh.x)) * (1.0 + 0.18 * st.k);
        float dlen2 = dpar * dpar + dperp * dperp + 1e-6;
        float da = atan(dperp, dpar);
        // 不规则类球体（v9，v12 性能：5 项谐波 → 3 项）+ 定向拉伸（泪滴形）
        // v13：加 hash 扇区扰动（把圆周分成 6 个扇区，每区一个随机凹凸值）
        // ——规则 sin 谐波是"规则花瓣"，叠加扇区 hash 才是"有机不规则"，
        //   真实受热液滴是随机凹凸的，不是多边形。扇区索引依赖像素角度，
        //   保留逐像素（每滴 1 次 hash）。
        float sector = floor(da * 3.0 / 3.14159265 + 3.0);   // 扇区索引 [0..6)
        float organic = hash11(sector * 13.0 + fi * 5.0 + sd) - 0.5;
        float wob = 1.0 + st.wamp * (
            0.46 * sin(2.0 * da + st.h1t + st.phase)
            + 0.32 * sin(3.0 * da + st.h4t - st.phase * 1.31)
            + 0.22 * sin(5.0 * da + st.h3t + st.phase * 0.83)
            + 0.30 * organic);
        wob *= 1.0 + st.wamp * WOB_STRETCH * (0.5 + 0.5 * cos(da - st.dirA));
        float d2 = dlen2 * wob * wob;
        float w = st.rr / d2;
        w *= 1.0 + st.sizzleW;
        F += w;
        g += -2.0 * w * d / d2;
        wRadSum += w * st.rad;
        wSum += w;
    }
    dropRad = wSum > 1e-5 ? wRadSum / wSum : R_MAIN_MIN;
    return F;
}

// 锅底温度场（v10）：返回 0..1 的归一化温度。同心圆燃气加热纹（频率由
// HEAT_RING_FREQ 控制）提供周期性骨架，fbm 噪声给不均匀加热，锅心温度
// 衰减（锅心受热最热，靠锅沿较冷）。最终用于反照率调制 + 红热/灶圈蓝
// 染色：t<0.4 冷铁皮、0.4~0.7 灶圈蓝反射、>0.7 红热。
float tempField(vec2 p) {
    float r = length(p);
    float ang = atan(p.y, p.x);
    // 同心圆加热纹（亮环/暗环交替）
    // 不均匀加热：两个尺度的各向异性噪声（v16：这是热斑的真实来源——材质
    // 差异、油膜厚薄、残渣，都是随机的，不是规则同心圆）
    // v12 性能：fbm 4 倍频 → vn（温度场只需一阶噪声）
    float heat = vn(p * 4.5 + 11.0) * 0.65 + vn(p * 13.0 - 5.0) * 0.35;
    // 锅心温度偏置 + 越靠锅沿越冷（燃气火焰集中在中心）
    float radial = smoothstep(0.95, 0.10, r);
    // 燃气火焰环留下的一圈灶痕：**单环、静态、不带角度项**（v16 的关键——
    // 加 ang 项就变成螺旋，加 ts 项就变成"一直在转"）
    float burner = exp(-pow((r - BURNER_R) / BURNER_W, 2.0));
    return clamp(HEAT_CENTER_BIAS * radial + 0.50 * heat
        + BURNER_K * burner, 0.0, 1.0);
}

// 锅底面：黑碳钢/铸铁（v10）× 真球冠 + 温度场 + 同心圆加热纹 + 红热
// + 灶圈蓝光 + 接触处沸腾气泡。v9 的拉丝不锈钢质感被替换：黑碳钢的
// 漫反射主导（PANDIFF 0.55）、镜面锐但能量低（PAN_SPEC 0.30），反射
// 的不是亮天花板，而是更暗的锅周环境——这是炒锅的本色。
// v15：法线由 ray-sphere 求交给出（真 3D），不再用 p 空间的伪球冠解析式。
// Pw = 锅面上的 3D 点（单位：锅口半径=1），Nw = 该点球面法线。
vec3 bg(vec3 Pw, vec3 Nw, float ts) {
    vec2 p = Pw.xy;                 // 水平投影（温度场/拉丝纹仍按水平坐标取）
    float r = length(p);
    float ang = atan(p.y, p.x);

    float brush = vn(vec2(r * 260.0, ang * 3.0));
    float brushHi = vn(vec2(r * 720.0 + 40.0, ang * 9.0));
    vec2 radialDir = p / max(r, 1e-4);
    // 真球面法线 + 拉丝微扰动（v15：曲率不再是常量近似，是几何算出来的）
    vec3 n = normalize(Nw + vec3(
        (brushHi - 0.5) * BRUSH_PERTURB * radialDir, 0.0));

    vec3 refl = 2.0 * n.z * n - vec3(0.0, 0.0, 1.0);
    vec3 spec = envMap(refl);
    float fres = 0.55 + 0.40 * pow(1.0 - n.z, 3.0);
    // 温度场 + 同心圆加热纹调制反照率
    float temp = tempField(p);
    // 锅心红热（高温区往暗红偏）+ 温区灶圈蓝（中等温度偏蓝黑）
    vec3 heatRed = vec3(0.32, 0.06, 0.02);     // 红热色（暗红，避免刺眼）
    vec3 flameBlue = vec3(0.04, 0.07, 0.16);    // 灶圈蓝光（深蓝黑）
    vec3 coldSteel = vec3(0.06, 0.06, 0.07);   // 冷碳钢色
    vec3 baseColor = coldSteel
        + flameBlue * smoothstep(0.40, 0.65, temp) * (1.0 - smoothstep(0.70, 0.85, temp))
        + heatRed * smoothstep(0.70, 0.95, temp) * HEAT_TINT;
    // v16：删掉随时间漂移的同心圆反照率调制（那个 ts·DRIFT 项就是锅底"一
    // 直在转"的东西）。改成**静态**的使用痕迹噪声——真实锅底的划痕/油膜是
    // 固定的，不会自己游动。
    float ringK = 1.0 + HEAT_RING_K * (vn(p * 9.0 + 31.0) - 0.5) * 2.0;
    vec3 albedo = baseColor * ALBEDO_BASE * ringK
        + vec3(0.020) * (brush - 0.5)
        + vec3(0.012) * (brushHi - 0.5);
    vec3 c = albedo * envMap(vec3(0.0, 0.0, 1.0)) * PAN_DIFF
        + spec * PAN_SPEC * fres;

    // 球面径向明暗（v13）：球冠法线 n.z 随半径递减（锅心竖直→锅沿倾斜），
    // 反射环境的明暗随此渐变——锅心反射亮天花板、锅沿反射暗墙。这是
    // "球面"的视觉身份证；黑锅漫反射会淹没它（= "平底"的病根），这里
    // 用 n.z 显式补一道径向明暗，让球冠曲率可读
    c *= 0.55 + 0.45 * n.z;

    c *= 0.92 + 0.16 * vn(p * 3.2 + 7.0);   // v12 性能：fbm → vn（锅底使用痕迹一阶噪声够）

    // 锅心聚油 + 凹底自阴影：中心压暗（"凹下去"的深度线索之一）
    c *= 1.0 - BOWL_DARK * smoothstep(0.85, 0.10, r);

    // 接触处沸腾气泡（v16.1）——水珠正下方锅面被高温烫成沸腾区，密集小
    // 气泡群（高频值噪声）作为暗点；只覆盖锅心附近的"沸区"（圆环掩模，
    // 避开锅沿冷区）。**v10 写 sin(ts·5.7 + r·60) 两个 bug 全删**：
    //   r·60 → 9.5 圈同心圆（"圈圈"）
    //   ts·5.7 → 0.9Hz 脉动（"生锈效果一会有一会没有"——用户原话）
    // 现在纯静态：气泡暗斑是**固定的锅面材质痕迹**（像烫斑/油污），不随
    // 时间变——材质不能变来变去。
    float bubbleMask = smoothstep(0.05, 0.35, temp) * smoothstep(0.85, 0.55, r);
    float bubble = vn(p * BUBBLE_FREQ);
    float bubbleDark = bubbleMask * smoothstep(0.55, 0.30, bubble);
    c *= 1.0 - BUBBLE_DARKEN * bubbleDark;

    // 远侧底面被内壁轻微遮挡（俯视时远侧底边有一点内壁阴影）
    c *= 1.0 - 0.12 * smoothstep(0.5, 0.95, p.y / max(1e-4, 1.0));
    // 全局压暗保持（v8 立的水珠暗底玻璃体的基调）
    c *= 0.78;
    return c;
}

// 沿口半径（随方位变化）：深锅俯视透视——远侧（画面上方）内壁看得见
// 一大圈（高），近侧只剩沿口卷边（窄）。
float wallTopR(vec2 p, float pr) {
    float ny = p.y / max(pr, 1e-4);
    return 1.0 + WALL_W * mix(0.55, 1.50, smoothstep(-0.9, 0.9, ny));
}

// 内壁环带着色：近侧（画面下方）迎光亮、远侧背光暗 + 沿口卷边高光
vec3 wallColor(vec2 p, float pr, float wTop) {
    vec3 c = vec3(0.30, 0.31, 0.33);
    float wallShade = mix(1.25, 0.34, smoothstep(-0.45, 0.65, p.y));
    float winSide = 0.80 + 0.35 * clamp(
        dot(normalize(p + 1e-5), normalize(WIN_DIR.xy)), 0.0, 1.0);
    c *= wallShade * winSide;
    // 内壁拉丝（同底面纹向）
    float ang = atan(p.y, p.x);
    c *= 0.92 + 0.16 * vn(vec2(pr * 300.0, ang * 3.0));
    // 越靠口沿越亮（深度渐变）
    c *= mix(0.75, 1.25, smoothstep(1.0, wTop, pr));
    // 沿口卷边：窄亮弧（金属外沿反光，下侧映台面更暖）
    float rimK = exp(-pow((pr - wTop) * 55.0, 2.0));
    c += mix(vec3(0.25, 0.22, 0.19), vec3(0.95, 0.97, 1.0),
        smoothstep(0.2, -0.4, p.y)) * rimK * 0.85;
    return c;
}

// 外壁 + 台面：外壁暗钢渐变，台面暖木 + 锅底投影
vec3 outerColor(vec2 p, float pr, float sd, float wTop) {
    // 外壁（锅外侧，背光）
    float outerBand = smoothstep(wTop, wTop + OUTER_W, pr);
    vec3 wall = vec3(0.09, 0.09, 0.10)
        * mix(1.3, 0.6, smoothstep(-0.5, 0.6, p.y));
    // 台面：暖木色微噪 + 使用痕迹（v17：木纹是软背景，fbm→fbm3）
    vec3 counter = vec3(0.15, 0.115, 0.085)
        * (0.75 + 0.5 * vn(p * 22.0 + sd));
    counter *= 0.85 + 0.3 * fbm3(p * 3.0 + 31.0);
    vec3 c = mix(wall, counter, outerBand);
    // 锅的落影（台面上椭圆软影）
    float shadow = exp(-pow((pr - (wTop + OUTER_W + 0.06)) * 3.2, 2.0));
    c *= 1.0 - 0.35 * smoothstep(0.0, 0.5, shadow);
    return c;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    // uTilt 视差（设备倾斜）：锅/珠/壁整体轻移——状态预通道按格子索引
    // 写状态（不依赖 q），主 pass 整体平移不破坏锅珠相对位置；只进几何
    vec2 q = sceneUV(vec2(0.5, 0.47) - uTilt * 0.04);
    float aspect = aspectRatio();

#ifndef PAN_NO_STATE_TEX
    // 状态预通道分支：C++ 侧以 20×PAN_STATE_ROWS 小视口、uStateMode=1 调起，
    // x=滴索引、y=槽号，每格写出 PanDrop 的一个 vec4（主 pass 见 fetchDrop）
    if (uStateMode > 0.5 && uStateMode < 1.5) {
        float fi = min(floor(vUV.x * float(DROPLET_COUNT)), float(DROPLET_COUNT - 1));
        float slot = floor(vUV.y * float(PAN_STATE_ROWS));
        PanDrop s = dropState(fi, ts, sd);
        if (slot < 0.5) {
            fragColor = vec4(s.pos, s.rr, s.rad);
        } else if (slot < 1.5) {
            fragColor = vec4(s.vh, s.k, s.fores);
        } else if (slot < 2.5) {
            fragColor = vec4(s.wamp, s.phase, s.dirA, s.sizzleW);
        } else {
            fragColor = vec4(s.h1t, s.h4t, s.h3t, 0.0);
        }
        return;
    }
#endif

    // ---- v15 真 3D：屏幕 → 锅面（光线-球面求交）----
    // s 空间：单位 = 锅口半径（1.0 = 锅口），原点 = 锅心的投影位置。
    // 注意**不再减 PAN_CENTER**——v8~v14 把锅心放在锅口椭圆中心是错的，
    // 真实几何里锅心在椭圆中心下方 D·sinα（q 单位 = D·sa·RX）。
    float RX = PAN_FILL * aspect;
    float RY = RX * TILT_COS;
    vec2 s = q / RX;
    vec3 Ph, Nh;
    bool onPan = panHit(s, Ph, Nh);
    float pr = length(Ph.xy);          // 水平半径（0=锅心，1=锅口）
    vec2 p = Ph.xy;                    // 水平投影（温度场/方位角仍按它取）

    // 锅口椭圆（半径 1 的圆在斜视下的投影：半轴 (1, cosα)，中心 (0, D·sinα)）
    float rimE = length(vec2(s.x, (s.y - PAN_DEPTH * TILT_SIN) / TILT_COS));
    float panMask = onPan ? smoothstep(1.015, 0.985, rimE) : 0.0;
    // v17 掩模先行：锅沿/外壁掩模提前算出——锅椭圆之外 ~70% 像素的
    // field()/bg()/水珠着色结果都会被 panMask/dropMask 归零，v16 以前这些
    // 重活在全屏白算。现在只在掩模有效的像素上计算；阈值 0.004 以下的
    // 混叠贡献 <0.4% 亮度，肉眼不可辨。
    float wallMask = (1.0 - panMask) * smoothstep(1.12, 1.0, rimE);
    float outerMask = smoothstep(1.0, 1.04, rimE);
    float heat = smoothstep(1.0, 0.1, pr);

    vec3 col = vec3(0.0);
    float m = 0.0;
    if (max(panMask, wallMask) > 0.004) {
        // 热空气扭曲（锅面全域）
        vec2 sw = s + (0.004 + 0.005 * heat)
            * vec2(vn(s * 13.0 + ts * 1.1), vn(s * 13.0 + 31.0 - ts * 0.9));
        vec3 Ph2, Nh2;
        if (!panHit(sw, Ph2, Nh2)) { Ph2 = Ph; Nh2 = Nh; }
        vec2 pw = sw;

        // ---- 锅面域：元球场 + 高度场 + 贴合阴影（变量提升到本级供着色复用）----
        float F = 0.0;
        vec2 g = vec2(0.0);
        float dropRad = R_MAIN_MIN;
        float dh = 0.0;
        float hDome = 0.0;
        vec2 gn0 = vec2(1.0, 0.0);
        float awayWin = 0.0;
        float ringSh = 0.0;
        float ao = 0.0;
        if (panMask > 0.004) {
            F = field(pw, ts, sd, g, dropRad) * panMask;
            F *= 1.0 + BEAT_BOIL * uBeat * sin(ts * 31.0);
            m = smoothstep(ISO_LO, ISO_HI, F);

            // ---- 高度场法线：h = √(1−1/F)（球冠解析解）----
            float Fin = max(F, 1.0);
            // v16 扁平化 = 毛细长度（Bond number）物理，替代 v14 的固定 DROP_FLAT：
            //   液滴厚度 h ≈ 2·l_c（与体积无关），球形上限 h=R
            //   ⟹ hDome 上限 = min(1, 2·l_c / R)
            //   · 小珠（R < l_c）→ 1（半球，表面张力主导）
            //   · 大珠（R = 11mm）→ 0.48（摊成厚度恒定的扁饼，重力主导）
            //   这就是莱顿弗罗斯特大液滴的真实形态——"锅底的一摊"，不是立起来的球
            float flatK = min(1.0, 2.0 * CAPILLARY / max(dropRad, 2e-3));
            hDome = sqrt(max(1.0 - 1.0 / Fin, 0.0)) * flatK;
            dh = 0.5 * flatK / (Fin * Fin * max(hDome, 0.035));

            // ---- 贴合阴影（同一份场推出；背光侧更深）----
            gn0 = g / (length(g) + 1e-4);
            float azq = atan(pw.y, pw.x);
            awayWin = 0.5 - 0.5 * cos(azq - atan(WIN_DIR.y, WIN_DIR.x));
            ringSh = smoothstep(0.30, ISO_LO, F) * (1.0 - m) * panMask
                * (0.75 + 0.5 * awayWin);
            ao = smoothstep(0.06, 0.30, F) * (1.0 - m) * panMask;
        }

        // v15：锅面（锅底 + 内壁，连续的球冠）由**真 3D 法线统一着色**。
        // 删掉 v8~v14 的 innerWallColor 内壁环带合成——那是一大片被涂得比锅底
        // 还亮的均匀灰（0.24~0.34 vs 锅底 0.227），宽度还是拍脑袋的 BOTTOM_FAR
        // =0.58 撑出来的 42% 锅半径，视觉上就是"锅里装了 1/3 高的水"。真实几
        // 何下内壁是背光面，法线朝内上方，反射暗环境 → 自然比锅底暗。
        // v17：bg() 只算一次，结果（panBase）同时供锅底合成与水珠折射复用
        // （v16 以前 bg 以相同入参被调用两次——v12 注释声称的"合并"实际没做）。
        vec3 panBase = bg(Ph2, Nh2, ts);
        col = panBase;
        col *= 1.0 - CONTACT_DARKEN * ringSh - AO_DARKEN * ao;
        // 水珠可见域 = 整个命中锅面的区域（是否爬太高由 field() 的 θ_max 限制）
        float dropMask = panMask;

        if (panMask > 0.004) {
            vec3 n = normalize(vec3(-g * dh, 1.0));
            // ---- 水珠：折射/反射能量混合 ----
            vec3 V = vec3(0.0, 0.0, 1.0);
            float ndv = max(dot(n, V), 0.0);
            float fres = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);

            // v17：删掉从未参与采样的折射偏移 ruv（死代码），折射底色直接
            // 复用 panBase——输出与 v16 逐像素等价
            vec3 through = panBase * 1.35 + envMap(vec3(0.0, 0.0, 1.0)) * LENS_GAIN;
            through *= vec3(0.970, 0.985, 0.998);
            through *= exp(-(1.0 - n.z) * ABSORB_R * vec3(1.35, 1.0, 0.82));
            // 折射体边缘压暗：接触线附近全反射 + 贴合阴影把光"关"在滴内，
            // 轮廓因此清晰（v6 通体均匀亮 = 哑光玻璃珠的病根）
            through *= 1.0 - RIM_DARK * smoothstep(0.45, 0.15, n.z);
            through += WIN_COLOR * pow(ndv, 7.0) * FOCUS_GAIN;
            // 薄缘透光（v9）：接触线最外缘一圈背景透亮——真实液滴边缘薄如透镜，
            // 背景光从薄处穿过来。RIM_DARK 压暗的是 0.06~0.45 的内缘反射区（暗边），
            // 这层亮线只贴 <0.06 的最外沿（n.z 越低越靠边缘），叠加出"暗边 + 亮线"
            through += panBase * RIM_LIGHT
                * (1.0 - smoothstep(0.06, 0.18, n.z));

            vec3 refl = 2.0 * ndv * n - V;
            vec3 mirrored = envMap(refl);

            // 水珠漫反射（v9）：天空光 diffuse——纯镜面球不存在，表面有微漫
            // 反射，暗侧不至于死黑（ndv 越朝上越亮，像湿润的水面被天光点亮）
            vec3 dropDiff = envMap(vec3(0.0, 0.0, 1.0)) * ndv * DROP_DIFF;

            float crescent = smoothstep(0.35, 0.10, n.z)
                * pow(max(-dot(gn0, normalize(WIN_DIR.xy)), 0.0), 1.6);
            float sparkle = pow(max(dot(refl, BULB_DIR), 0.0), 220.0)
                * (0.6 + 0.4 * vn(pw * 180.0 + ts * 5.0));
            // 灯泡泛光高光（v9）：中锐（pow 60）暖色高光——窗光针尖（pow 320）
            // 之外的真实水珠还有一枚灯泡泛光，双层高光更接近实拍
            float bulbGlow = pow(max(dot(refl, BULB_DIR), 0.0), 60.0)
                * (0.65 + 0.35 * vn(pw * 60.0 + ts * 2.3));
            // 窗光针尖高光：每颗水珠一枚（真实照片里水珠的"湿润感"几乎全在
            // 这枚高光上；位置由法线决定，随形状游动自然滑移）
            float glint = pow(max(dot(refl, WIN_DIR), 0.0), 320.0);
            // 天光高光（v11）：中锐（pow 12）的顶部泛光——湿润水面被天光整体
            // 点亮的那层光泽，弥补"纯镜面针尖 + 漫反射"之间的过渡档
            float skyGlint = pow(max(dot(refl, vec3(0.0, 0.0, 1.0)), 0.0), 12.0)
                * (0.7 + 0.3 * vn(pw * 90.0 + ts * 1.7));

            vec3 drop = mix(through, mirrored, fres);
            drop += dropDiff;
            drop += WIN_COLOR * crescent * CRESCENT_GAIN;
            drop += WIN_COLOR * glint * GLINT_GAIN;
            drop += ROOM_SKY * skyGlint * SKY_GLINT;
            drop += BULB_COLOR * (sparkle * SPARKLE_GAIN + bulbGlow * BULB_GLOW)
                * (0.7 + 0.6 * uTreble);

            // ---- 接触线薄膜干涉：蒸气垫 + 液滴薄缘的牛顿环虹彩 ----
            float optPath = hDome * IRID_PATH_NM;
            float iridZone = exp(-hDome * hDome * IRID_FALLOFF);
            drop += thinFilm(optPath) * iridZone * IRID_GAIN * (0.55 + 0.45 * awayWin);

            // 水珠只落在可见底面上（不爬上内壁/沿口）
            col = mix(col, drop, m * dropMask);

            // ---- 飞溅星芒（v10 简化实现）---- 
            // 真实粒子系统需几何 shader / 多 pass，单 pass fragment 内做全套代价
            // 太高；这里用"星芒"作为视觉近似：液滴边缘外的辐射状短亮线群（hash
            // 噪声调向打破对称，6 角星芒 + 时间相位），只在液滴边缘薄带出现
            // ——液滴"看起来"在往外溅小液滴。濒死期（m 边缘 + treble 高）触发更
            // 强。真正的方向飞溅（沿速度方向）需要把 field 内部 vel 传出，超出
            // 当前架构；视觉上星芒 + 噪点足够让用户感知"爆裂"
            float splashBand = (1.0 - m) * smoothstep(0.0, 0.30, m); // 液滴边缘薄带
            float splashAz = atan(pw.y, pw.x)
                + vn(pw * 47.0 + sd) * 0.9   // 角度噪打破对称
                + ts * 0.7;                   // 星芒慢转
            float splashStar = pow(0.5 + 0.5 * cos(splashAz * 6.0), 22.0);
            float splashNoise = vn(pw * 110.0 + ts * 4.0);  // 噪点增强飞溅密度感
            col += WIN_COLOR * splashBand * (splashStar + 0.35 * splashNoise)
                * SPLASH_GAIN * (0.6 + 0.6 * uTreble) * (1.0 - m) * panMask
                * awayWin * dropMask;

            // ---- 接触处白烟（v10）——每颗水珠周围小范围浓白雾，活跃时更浓----
            // 沸腾的水珠在接触处先冒一小团白烟，再合并到锅口大蒸汽层。位置：
            // 液滴边缘（m<1 的过渡带），半径比水珠大约 30%
            float localSteam = (1.0 - m) * smoothstep(0.05, 0.40, m)
                * vn(pw * 9.0 + ts * 1.3 + vec2(sd));
            vec3 whiteSteam = vec3(0.78, 0.80, 0.84);
            col = mix(col, whiteSteam, localSteam * STEAM_LOCAL_GAIN
                * (0.65 + 0.55 * uBass) * panMask * dropMask);

            // ---- 焦散环：液滴透镜聚焦上方光，接触线外缘亮边（光侧，底面上）----
            float caustic = exp(-pow((F - 0.80) / 0.12, 2.0));
            col += WIN_COLOR * caustic * CAUSTIC_GAIN * (1.0 - m) * panMask
                * awayWin * dropMask;
        }
    }

    // ---- 锅沿卷边 / 外壁+台面（锅口之外环带；v15 用真实锅口椭圆 rimE）----
    // 锅沿：rimE≈1 的一圈卷边高光；再外面是锅外壁 + 台面。
    // v17：各自只在掩模有效的像素上计算（v16 以前全屏求值后按 0 权混入）
    if (wallMask > 0.004) {
        vec3 wallC = wallColor(p, rimE, 1.0)
            * (1.0 - 0.10 * heat * smoothstep(1.0, 1.18, rimE));
        col = mix(col, wallC, wallMask);
    }
    if (outerMask > 0.004) {
        col = mix(col, outerColor(p, rimE, sd, 1.0), outerMask);
    }

    // ---- 蒸汽：从锅口整个开口面升起（v8 修正位置）----
    // 源强 = 锅口椭圆内部（锅心最强、沿口衰减、锅外为零——蒸汽是从锅里
    // 冒出来的，不是从远侧沿一条线喷）；高度越高越散、越淡。
    // v17：源强为 0 的像素跳过蒸汽纹理计算（锅外/锅侧大半屏），缕纹
    // fbm→fbm3（软特征降阶）。
    float openR = rimE;                             // 锅口归一化坐标（v15 真椭圆）
    float src = smoothstep(1.10, 0.45, openR);      // 开口面内部为源（锅心最强）
    if (src > 0.003) {
        float baseY = PAN_DEPTH * TILT_SIN + RY * 0.20; // 源起点：锅口平面高度
        float hA = clamp((q.y - baseY) / (0.68 - baseY), 0.0, 1.0);
        float sx = s.x;
        float spread = exp(-sx * sx * mix(3.0, 1.2, hA));  // 越高越散开
        // 竖缕纹理随时间上移 + 域扭曲（蒸汽不是竖直细条，是扭动的气柱）
        vec2 wq = vec2(q.x * 8.0 + sd, q.y * 3.0 - ts * STEAM_RISE);
        wq += vec2(vn(wq * 1.7 + ts * 0.35), vn(wq * 1.9 - ts * 0.31));
        float wisp = smoothstep(0.42, 0.72, fbm3(wq));
        float dens = src * spread * wisp * smoothstep(0.0, 0.08, hA)
            * (1.0 - 0.72 * hA);
        vec3 steamCol = vec3(0.68, 0.71, 0.76)
            * (0.75 + 0.45 * smoothstep(0.25, -0.35, q.x));  // 窗侧逆光更亮
        col = mix(col, steamCol, dens * STEAM_ALPHA * (0.8 + 0.5 * uBass));
        col += steamCol * dens * 0.10;
    }

    // ---- 照片后期链 ----
    col = filmic(col);
    col *= 1.0 - 0.22 * dot(q * 1.1, q * 1.1);
    float L = dot(col, vec3(0.299, 0.587, 0.114));
    col += vec3((hash21(vUV * uRes + fract(ts) * 13.0) - 0.5)
        * mix(0.014, 0.004, smoothstep(0.0, 0.5, L)));

    col = applyTransition(col);

    gl_FragColor = vec4(col, 1.0);
}
