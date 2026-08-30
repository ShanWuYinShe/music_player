// pan.frag：高温热炒菜锅上的水滴动力学（照片级 v12：性能优化——软渲染不再卡死）。
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
const float PAN_SQUASH = 0.75;     // y 压扁（俯视透视）
const vec2 PAN_CENTER = vec2(0.0, -0.03);
const float BOWL_RADIUS = 1.10;    // 锅底球冠半径（锅局部坐标；v11 1.30→1.10）。
                                   //   球面曲率 = 1/R：1.30 时锅心曲率太小（视觉
                                   //   "平"——用户反馈"锅最底部为什么是平的"）。
                                   //   1.10 让锅心明显弯曲（深炒锅），底缘处法线
                                   //   ~57°——真正的"球体锅身"观感。
const float BOWL_DARK = 0.38;      // 锅心聚油/自阴影压暗（v11 0.30→0.38：
                                   //   压掉"一滩水"的亮锅心——水珠才是亮体，
                                   //   锅心聚油区应该暗）
const float BOTTOM_NEAR = 0.92;    // 底缘半径（近侧）：近侧内壁被沿口遮住，
                                   //   只留一条缝——v8 真·凹底的几何核心
const float BOTTOM_FAR = 0.58;     // 底缘半径（远侧）：远侧内壁宽，底缘
                                   //   收进椭圆内部一大圈
const float WALL_W = 0.32;         // 内壁环带基准宽度（v11 0.28→0.32：球面
                                   //   锅身 + 更宽内壁 = 深炒锅的"看进去"
                                   //   透视更扎实）
const float OUTER_W = 0.10;        // 外壁环带宽度
const float PAN_DIFF = 0.55;       // 钢面漫反射占比（v10 黑碳钢 0.18→0.55：
                                   //   哑光磨砂碳钢的漫反射是主项，不是镜面；
                                   //   亮反射会让锅变成"厨房用品"质感，不像
                                   //   实拍黑炒锅）
const float PAN_SPEC = 0.30;       // 钢面镜面强度（v10 0.72→0.30：黑碳钢只
                                   //   在窗光直射处出微高光，不抢戏）
const float BRUSH_PERTURB = 0.045; // 拉丝法线扰动（v10 0.060→0.045：黑碳钢
                                   //   比拉丝不锈钢更光滑，只有极轻的拉丝质感）
const float ALBEDO_BASE = 0.07;     // v10 锅底反照率基色（0.14→0.07：黑碳钢
                                   //   比不锈钢暗 1 个 stops）
const float HEAT_TINT = 0.55;       // 锅心红热混入强度（温度 > 0.7 时往暗红
                                   //   偏——参考图锅心是暗红热区）
const float FLAME_BLUE = 0.30;      // 灶圈蓝光混入强度（温度 0.4~0.7 区间，
                                   //   燃气反射的蓝色调）

// ---- 水滴群（锅局部坐标：单位圆 = 锅口内沿）---------------------------------
const int DROPLET_COUNT = 28;      // v12 性能：44→28（22 主滴 + 6 卫星）——
                                   //   field() 循环是逐像素 × 逐滴的，44 滴在
                                   //   软渲染下卡死；降 36% 保留大小珠层次
const float SATELLITE_FROM = 22.0;
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
const float WOB_SMALL_AMP = 0.05;
const float WOB_BIG_AMP = 0.20;
const float WOB_SIZE_LO = 0.060;
const float WOB_SIZE_HI = 0.240;
const float WOB_STRETCH = 0.40;    // 定向拉伸幅度（v9：受热不均 → 液滴沿
                                   //   受热最弱方向拉长成泪滴形，非球对称）
const float WOB_TURN = 0.32;       // 定向拉伸方向随受热慢转（弧度/滴生命周期）
const float WOB_BOIL_AMP = 0.50;   // v10 沸腾变形振幅系数（boilK × WOB_BOIL_AMP
                                   //   加到 wob 振幅上——沸腾时形状剧烈变形）

// ---- 锅底温度场（v10）---------------------------------------------------
const float HEAT_RING_FREQ = 28.0; // 同心圆加热纹频率（每单位多少环）
const float HEAT_RING_DRIFT = 0.20;// 加热纹慢漂（锅热时纹路在游动）
const float HEAT_RING_K = 0.18;    // 加热纹反照率调制深度（0.82~1.18）
const float HEAT_CENTER_BIAS = 0.35;// 锅心温度偏置（同心圆纹整体偏向锅心热）
const float BUBBLE_DARKEN = 0.55;  // 接触处小气泡暗化强度
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
const float ORBIT_RATE = 0.18;     // 绕锅心盘旋基础角速度（rad/s，缓慢）
const float ORBIT_RATE_K = 0.30;   // 每滴角速度差异系数

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

// 可见底面边缘半径（随方位变化）——v8 真·凹底的几何核心：
// 远侧（画面上方）底缘收到 0.58（露出一大圈内壁），近侧 0.92（内壁
// 被沿口遮住只剩一条缝）。锅底因此是"比锅口小的椭圆"，俯视透视成立。
float bRAt(vec2 p) {
    float ny = p.y / max(length(p), 1e-4);
    return mix(BOTTOM_NEAR, BOTTOM_FAR, smoothstep(-0.9, 0.9, ny));
}

// 水滴元球场（锅局部单位圆坐标）：F = Σ r²/d_eff²，g = ∇F。
// d_eff 含运动方向拉伸 + 角向谐波轮廓（不规则类球体）+ 受热震动 + 濒死泡沫化。
float field(vec2 p, float ts, float sd, out vec2 g) {
    g = vec2(0.0);
    float F = 0.0;
    for (int i = 0; i < DROPLET_COUNT; i++) {
        float fi = float(i);
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
        // 受热震动（v9）：蒸气垫把液滴顶起→落下，半径 ±6% 高频脉动——
        // 两个不可通约频率叠出"跳着"的活体感
        float heatHop = 1.0 + HEAT_JITTER * sin(age * (9.0 + 7.0 * h2) + fi * 3.7)
            * (0.5 + 0.5 * sin(age * (2.3 + 0.7 * h4) + fi * 1.9));
        // 沸腾半径脉动（v10）：boilK × BOIL_KICK 调制——沸腾时液滴高度
        // 大幅脉动（液滴在"咕嘟咕嘟"地翻）
        float boilKick = 1.0 + BOIL_KICK * boilK
            * sin(age * (BOIL_RATE * 2.7) + fi * 4.3);
        rr *= heatHop * boilKick;
        // 濒死弹跳：蒸气垫破裂前液滴在锅面上蹦跳（半径脉动 → 接触阴影
        // 与轮廓同步搏动；系数最低 0.72，不会反号）
        float hopK = smoothstep(PANIC_FROM, 1.0, lifeK);
        rr *= 1.0 + PANIC_HOP * hopK * sin(age * 36.0 + fi * 7.0);
        if (rr < FIELD_EPS) continue;
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
        pos += vec2(driftX, driftY) * dr * range;
        vel += vec2(driftX, driftY) * dr * range * 0.4;
        float oa = age * (ORBIT_RATE + ORBIT_RATE_K * h2)
            * (h4 < 0.5 ? -1.0 : 1.0);
        pos = rot(oa) * pos;
        vel = rot(oa) * vel;
        vec2 trem = TREMBLE_AMP * panic * (1.0 + TREMBLE_BASS * uBass)
            * vec2(sin(age * 23.0 + fi * 9.0), cos(age * 29.0 + fi * 4.0));
        pos += trem;
        // 等值面留在可见底面内（不许爬内壁/爬上沿口）——底面边缘随方位
        // 收拢（远侧 0.58 / 近侧 0.92），与 v8 凹底构图一致
        float bR = bRAt(pos);
        float maxR = bR - 2.3 * rad - 0.05;
        if (maxR > 0.0) {
            float pl = length(pos);
            if (pl > maxR) {
                pos *= maxR / pl;
            }
        } else {
            continue;
        }
        vec2 d = p - pos;
        float spd = length(vel);
        float k = clamp(spd * SPEED_STRETCH, 0.0, 0.6);
        vec2 vh = vel / max(spd, 1e-4);
        float dpar = dot(d, vh) * (1.0 - 0.24 * k);
        float dperp = dot(d, vec2(-vh.y, vh.x)) * (1.0 + 0.18 * k);
        float dlen2 = dpar * dpar + dperp * dperp + 1e-6;
        float wsize = smoothstep(WOB_SIZE_LO, WOB_SIZE_HI, rad);
        // 沸腾度调制 wob 振幅（v10）：沸腾时形状剧烈变形——大珠在
        // lifeK 中段 (0.5~0.9) 变形振幅 ×2+，濒死期 (lifeK>0.9) ×3 接近
        // 爆裂态（飞溅条纹的视觉基础）
        float boilShape = 1.0 + boilK * WOB_BOIL_AMP
            * (0.5 + 1.5 * smoothstep(0.85, 0.99, lifeK));
        float wamp = mix(WOB_SMALL_AMP, WOB_BIG_AMP, wsize) * boilShape;
        float wrate = (0.6 + 0.9 * h2) * mix(1.8, 0.7, wsize)
            * (1.0 + 0.6 * boilK * smoothstep(0.85, 0.99, lifeK));
        float da = atan(dperp, dpar);
        // 不规则类球体（v9，v12 性能：5 项谐波 → 3 项——保留 2/3/5 阶的
        //   "非圆非椭圆"轮廓，砍掉 4/7 阶高频细节；每滴少 2 次 sin，在
        //   逐像素 × 逐滴循环里是实打实的成本）+ 定向拉伸（泪滴形）
        float wob = 1.0 + wamp * (
            0.46 * sin(2.0 * da + h1 * TAU + age * wrate)
            + 0.32 * sin(3.0 * da + h4 * TAU - age * wrate * 1.31)
            + 0.22 * sin(5.0 * da + h3 * TAU + age * wrate * 0.83));
        float dirA = h2 * TAU + age * (WOB_TURN * 0.5 + 0.12 * heatK);
        wob *= 1.0 + wamp * WOB_STRETCH * (0.5 + 0.5 * cos(da - dirA));
        float d2 = dlen2 * wob * wob;
        float w = rr / d2;
        float sizzle = smoothstep(SIZZLE_FROM, 1.0, lifeK);
        // v12 性能：sizzle 噪声从 vn(p*150)（per-pixel 4 次 hash）改为
        // hash11（每滴 1 次，不依赖像素坐标）——濒死期液滴边缘沸腾抖动的
        // 观感等价，成本降 4 倍（逐像素 × 逐滴循环里是主要热点之一）
        w *= 1.0 + sizzle * (hash11(age * 7.0 + fi * 3.0 + sd * 0.01) - 0.5)
            * SIZZLE_AMP;
        F += w;
        g += -2.0 * w * d / d2;
    }
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
    float ring = 0.5 + 0.5 * sin(r * HEAT_RING_FREQ - r * 0.0);
    // 旋涡扰动让纹路不是死板的同心圆（参考图锅底有手摇动的不规则感）
    float swirl = sin(r * HEAT_RING_FREQ * 0.9 + ang * 1.7) * 0.5;
    ring = mix(ring, swirl, 0.3);
    // 不均匀加热（v12 性能：fbm 4 倍频 → vn 1 次——温度场的"不均匀"只需
    //   一阶噪声，4 倍频在锅底每像素 ×3 次 bg 调用下是纯浪费）
    float heat = vn(p * 4.5 + 11.0);
    // 锅心温度偏置 + 越靠锅沿越冷
    float radial = smoothstep(0.95, 0.10, r);
    return clamp(0.35 * radial + 0.45 * ring + 0.20 * heat, 0.0, 1.0);
}

// 锅底面：黑碳钢/铸铁（v10）× 真球冠 + 温度场 + 同心圆加热纹 + 红热
// + 灶圈蓝光 + 接触处沸腾气泡。v9 的拉丝不锈钢质感被替换：黑碳钢的
// 漫反射主导（PANDIFF 0.55）、镜面锐但能量低（PAN_SPEC 0.30），反射
// 的不是亮天花板，而是更暗的锅周环境——这是炒锅的本色。
vec3 bg(vec2 p, float ts) {
    float r = length(p);
    float ang = atan(p.y, p.x);

    float brush = vn(vec2(r * 260.0, ang * 3.0));
    float brushHi = vn(vec2(r * 720.0 + 40.0, ang * 9.0));
    vec2 radialDir = p / max(r, 1e-4);
    // 球冠法线（v9 解析）：p / √(R²−r²) ——曲率集中在锅沿
    float bowlSlope = 1.0 / sqrt(max(BOWL_RADIUS * BOWL_RADIUS - r * r, 1e-4));
    vec3 n = normalize(vec3(
        (brushHi - 0.5) * BRUSH_PERTURB * radialDir + p * bowlSlope, 1.0));

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
    // 同心圆加热纹作为反照率调制（亮环 1.15×、暗环 0.85×）
    float ringK = mix(1.0 - HEAT_RING_K, 1.0 + HEAT_RING_K,
        0.5 + 0.5 * sin(r * HEAT_RING_FREQ + ts * HEAT_RING_DRIFT));
    vec3 albedo = baseColor * ALBEDO_BASE * ringK
        + vec3(0.020) * (brush - 0.5)
        + vec3(0.012) * (brushHi - 0.5);
    vec3 c = albedo * envMap(vec3(0.0, 0.0, 1.0)) * PAN_DIFF
        + spec * PAN_SPEC * fres;

    c *= 0.92 + 0.16 * vn(p * 3.2 + 7.0);   // v12 性能：fbm → vn（锅底使用痕迹一阶噪声够）

    // 锅心聚油 + 凹底自阴影：中心压暗（"凹下去"的深度线索之一）
    c *= 1.0 - BOWL_DARK * smoothstep(0.85, 0.10, r);

    // 接触处沸腾气泡（v10）——水珠正下方锅面被高温烫成沸腾区，密集小
    // 气泡群（高频值噪声）作为暗点；只覆盖锅心附近的"沸区"（圆环掩
    // 模，避开锅沿冷区）
    float bubbleMask = smoothstep(0.05, 0.35, temp) * smoothstep(0.85, 0.55, r);
    float bubble = vn(p * BUBBLE_FREQ);
    float bubbleDark = bubbleMask * smoothstep(0.55, 0.30, bubble)
        * (0.5 + 0.5 * sin(ts * 5.7 + r * 60.0));
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

// 可见内壁环带（底缘 → 沿口之间）：远侧宽且映天花板（亮）、近侧窄暗；
// 沿壁面从底缘（暗）到沿口（亮）渐变。这一圈是"看进锅里"的深度证据。
vec3 innerWallColor(vec2 p, float pr, float bR) {
    float ny = p.y / max(pr, 1e-4);
    float shade = mix(0.50, 1.40, smoothstep(-0.9, 0.9, ny));
    float along = mix(0.55, 1.25, smoothstep(bR, 1.0, pr));
    float winSide = 0.80 + 0.35 * clamp(
        dot(normalize(p + 1e-5), normalize(WIN_DIR.xy)), 0.0, 1.0);
    float ang = atan(p.y, p.x);
    vec3 c = vec3(0.17, 0.18, 0.20) * shade * along * winSide;
    c *= 0.92 + 0.16 * vn(vec2(pr * 300.0, ang * 3.0));
    return c;
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
    // 台面：暖木色微噪 + 使用痕迹
    vec3 counter = vec3(0.15, 0.115, 0.085)
        * (0.75 + 0.5 * vn(p * 22.0 + sd));
    counter *= 0.85 + 0.3 * fbm(p * 3.0 + 31.0);
    vec3 c = mix(wall, counter, outerBand);
    // 锅的落影（台面上椭圆软影）
    float shadow = exp(-pow((pr - (wTop + OUTER_W + 0.06)) * 3.2, 2.0));
    c *= 1.0 - 0.35 * smoothstep(0.0, 0.5, shadow);
    return c;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    vec2 q = sceneUV(vec2(0.5, 0.47));
    float aspect = aspectRatio();

    // ---- 锅局部坐标（椭圆透视；单位圆 = 锅口内沿）----
    float RX = PAN_FILL * aspect;
    float RY = RX * PAN_SQUASH;
    vec2 pc = q - PAN_CENTER;
    vec2 p = pc / vec2(RX, RY);
    float pr = length(p);

    // 热空气扭曲（底面全域）
    float heat = smoothstep(1.0, 0.1, pr);
    vec2 pw = p + (0.004 + 0.005 * heat)
        * vec2(vn(p * 13.0 + ts * 1.1), vn(p * 13.0 + 31.0 - ts * 0.9));

    float panMask = smoothstep(1.02, 0.96, length(pw));

    vec2 g;
    float F = field(pw, ts, sd, g) * panMask;
    F *= 1.0 + BEAT_BOIL * uBeat * sin(ts * 31.0);
    float m = smoothstep(ISO_LO, ISO_HI, F);

    // ---- 高度场法线：h = √(1−1/F)（球冠解析解）----
    float Fin = max(F, 1.0);
    float hDome = sqrt(max(1.0 - 1.0 / Fin, 0.0));
    float dh = 0.5 / (Fin * Fin * max(hDome, 0.035));
    vec3 n = normalize(vec3(-g * dh, 1.0));

    // ---- 贴合阴影（同一份场推出；背光侧更深）----
    vec2 gn0 = g / (length(g) + 1e-4);
    float azq = atan(pw.y, pw.x);
    float awayWin = 0.5 - 0.5 * cos(azq - atan(WIN_DIR.y, WIN_DIR.x));
    float ringSh = smoothstep(0.30, ISO_LO, F) * (1.0 - m) * panMask
        * (0.75 + 0.5 * awayWin);
    float ao = smoothstep(0.06, 0.30, F) * (1.0 - m) * panMask;

    vec3 col = bg(pw, ts);
    col *= 1.0 - CONTACT_DARKEN * ringSh - AO_DARKEN * ao;

    // ---- 凹底构图：可见底缘随方位收拢，底缘与沿口之间是内壁环带 ----
    float bR = bRAt(p);
    float bottomMask = smoothstep(bR + 0.015, bR, pr);
    float innerWallMask = (1.0 - bottomMask)
        * smoothstep(1.02, 1.0, pr);
    col = mix(col, innerWallColor(p, pr, bR), innerWallMask);

    // ---- 水珠：折射/反射能量混合 ----
    vec3 V = vec3(0.0, 0.0, 1.0);
    float ndv = max(dot(n, V), 0.0);
    float fres = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);

    vec2 ruv = pw + gn0 * (1.0 - n.z) * REFRACT_LEN;
    // v12 性能优化：bg(ruv) 只算一次（原来折射 + 薄缘透光各调一次 = 2 次
    // 完整 bg，含 tempField+fbm+envMap 各两遍）——合并为一次复用
    vec3 bgRuv = bg(ruv, ts);
    vec3 through = bgRuv * 1.35 + envMap(vec3(0.0, 0.0, 1.0)) * LENS_GAIN;
    through *= vec3(0.970, 0.985, 0.998);
    through *= exp(-(1.0 - n.z) * ABSORB_R * vec3(1.35, 1.0, 0.82));
    // 折射体边缘压暗：接触线附近全反射 + 贴合阴影把光"关"在滴内，
    // 轮廓因此清晰（v6 通体均匀亮 = 哑光玻璃珠的病根）
    through *= 1.0 - RIM_DARK * smoothstep(0.45, 0.15, n.z);
    through += WIN_COLOR * pow(ndv, 7.0) * FOCUS_GAIN;
    // 薄缘透光（v9）：接触线最外缘一圈背景透亮——真实液滴边缘薄如透镜，
    // 背景光从薄处穿过来。RIM_DARK 压暗的是 0.06~0.45 的内缘反射区（暗边），
    // 这层亮线只贴 <0.06 的最外沿（n.z 越低越靠边缘），叠加出"暗边 + 亮线"
    through += bgRuv * RIM_LIGHT
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
    col = mix(col, drop, m * bottomMask);

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
        * awayWin * bottomMask;

    // ---- 接触处白烟（v10）——每颗水珠周围小范围浓白雾，活跃时更浓----
    // 沸腾的水珠在接触处先冒一小团白烟，再合并到锅口大蒸汽层。位置：
    // 液滴边缘（m<1 的过渡带），半径比水珠大约 30%
    // v12 性能：fbm → vn（白烟只需一阶噪声，fbm 4 倍频在此过度）
    float localSteam = (1.0 - m) * smoothstep(0.05, 0.40, m)
        * vn(pw * 9.0 + ts * 1.3 + vec2(sd));
    vec3 whiteSteam = vec3(0.78, 0.80, 0.84);
    col = mix(col, whiteSteam, localSteam * STEAM_LOCAL_GAIN
        * (0.65 + 0.55 * uBass) * panMask * bottomMask);

    // ---- 焦散环：液滴透镜聚焦上方光，接触线外缘亮边（光侧，底面上）----
    float caustic = exp(-pow((F - 0.80) / 0.12, 2.0));
    col += WIN_COLOR * caustic * CAUSTIC_GAIN * (1.0 - m) * panMask
        * awayWin * bottomMask;

    // ---- 内壁 / 外壁+台面（底面之外环带，按 pr 混合，无缝）----
    // 沿口半径随方位变化：远侧内壁高、近侧只剩卷边（深锅俯视透视）
    float wTop = wallTopR(p, pr);
    float wallMask = smoothstep(1.0, 1.03, pr)
        * smoothstep(wTop + 0.025, wTop, pr);
    float outerMask = smoothstep(wTop, wTop + 0.03, pr);
    vec3 wallC = wallColor(p, pr, wTop)
        * (1.0 - 0.10 * heat * smoothstep(1.0, 1.18, pr));
    col = mix(col, wallC, wallMask);
    col = mix(col, outerColor(p, pr, sd, wTop), outerMask);

    // ---- 蒸汽：从锅口整个开口面升起（v8 修正位置）----
    // 源强 = 锅口椭圆内部（锅心最强、沿口衰减、锅外为零——蒸汽是从锅里
    // 冒出来的，不是从远侧沿一条线喷）；高度越高越散、越淡。
    vec2 openN = pc / vec2(RX, RY);                 // 锅口归一化坐标
    float openR = length(openN);
    float src = smoothstep(1.10, 0.45, openR);      // 开口面内部为源（锅心最强）
    float baseY = PAN_CENTER.y + RY * 0.55;         // 源起点：锅口中部高度
    float hA = clamp((q.y - baseY) / (0.68 - baseY), 0.0, 1.0);
    float sx = pc.x / RX;
    float spread = exp(-sx * sx * mix(3.0, 1.2, hA));  // 越高越散开
    // 竖缕纹理随时间上移 + 域扭曲（蒸汽不是竖直细条，是扭动的气柱）
    vec2 wq = vec2(q.x * 8.0 + sd, q.y * 3.0 - ts * STEAM_RISE);
    wq += vec2(vn(wq * 1.7 + ts * 0.35), vn(wq * 1.9 - ts * 0.31));
    float wisp = smoothstep(0.42, 0.72, fbm(wq));
    float dens = src * spread * wisp * smoothstep(0.0, 0.08, hA)
        * (1.0 - 0.72 * hA);
    vec3 steamCol = vec3(0.68, 0.71, 0.76)
        * (0.75 + 0.45 * smoothstep(0.25, -0.35, q.x));  // 窗侧逆光更亮
    col = mix(col, steamCol, dens * STEAM_ALPHA * (0.8 + 0.5 * uBass));
    col += steamCol * dens * 0.10;

    // ---- 照片后期链 ----
    col = filmic(col);
    col *= 1.0 - 0.22 * dot(pc * 1.1, pc * 1.1);
    float L = dot(col, vec3(0.299, 0.587, 0.114));
    col += vec3((hash21(vUV * uRes + fract(ts) * 13.0) - 0.5)
        * mix(0.014, 0.004, smoothstep(0.0, 0.5, L)));

    col = applyTransition(col);

    gl_FragColor = vec4(col, 1.0);
}
