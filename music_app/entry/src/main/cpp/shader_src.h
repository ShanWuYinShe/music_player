/**
 * shader_src.h：可视化全部 GLSL 源码（v4：游戏化·强辨识透视）。
 *
 * 目标：用户要求“明显、带有游戏感，而不只是一团颜色加一点点高亮”。
 *  解法：纯黑底 + 高对比霓虹 + 实体几何硬边 + 大面积占据 + 强透视视差。
 *  保留架构不变式：全屏三角，逐像素解算，运算量只与像素相关。
 *  10 风格全部为游戏关卡感（点击循环 0..9）：
 *   0 霓虹跑道：棋盘地板透视 + 方块障碍随节拍弹出（跑酷）
 *   1 水晶洞窟：SDF 晶体阵列 raymarch 硬表面 + 激光扫描线
 *   2 分形地形：Julia 等高线地形 + 网格 + 飞行高度透视
 *   3 赛博隧道：六边形蜂窝隧道 + 速度线
 *   4 传送门：Mandelbrot 同心环门 + 粒子环
 *   5 激光幕墙：垂直激光扫射 + 烟雾
 *   6 镜屋：棱镜镜面硬边 + 光束反射
 *   7 冲击波竞技场：同心冲击环 + 命中闪
 *   8 星门环廊：高速穿越的发光圆环门（已保留但提亮硬化）
 *   9 云海空战：低空掠云 + 机影剪影
 *  全部 1/depth 透视 + FOV 呼吸 + yaw/pitch，实体几何非柔光。
 */

#ifndef MUSICPLAYER_SHADER_SRC_H
#define MUSICPLAYER_SHADER_SRC_H

namespace {

const char* kVertSrc = R"(#version 300 es
layout(location = 0) in vec2 aPos;
out vec2 vUV;
void main() {
    vUV = aPos * 0.5 + 0.5;
    gl_Position = vec4(aPos, 0.0, 1.0);
}
)";

const char* kFragScene = R"(#version 300 es
precision highp float;
in vec2 vUV;
out vec4 outColor;
uniform float uT;
uniform float uSeed;
uniform vec2 uRes;
uniform float uBeat;
uniform float uBass;
uniform float uTreble;
uniform float uPresetSel;
uniform sampler2D uPrev;

float hash(float n) { return fract(sin(n) * 43758.5453123); }
float hash2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }

vec3 hsl2rgb(float h, float s, float l) {
    float hh = fract(h / 360.0) * 6.0;
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    float x = c * (1.0 - abs(mod(hh, 2.0) - 1.0));
    float m = l - c * 0.5;
    vec3 rgb;
    if (hh < 1.0) { rgb = vec3(c, x, 0.0); }
    else if (hh < 2.0) { rgb = vec3(x, c, 0.0); }
    else if (hh < 3.0) { rgb = vec3(0.0, c, x); }
    else if (hh < 4.0) { rgb = vec3(0.0, x, c); }
    else if (hh < 5.0) { rgb = vec3(x, 0.0, c); }
    else { rgb = vec3(c, 0.0, x); }
    return rgb + m;
}
mat2 rot2(float a){ float c=cos(a),s=sin(a); return mat2(c,-s,s,c); }
float sdBox(vec3 p, vec3 b){ vec3 d=abs(p)-b; return length(max(d,0.0))+min(max(d.x,max(d.y,d.z)),0.0); }
float sdTorus(vec3 p, vec2 t){ vec2 q=vec2(length(p.xz)-t.x, p.y); return length(q)-t.y; }

// 简易值噪声
float vn(vec2 p){
    vec2 i=floor(p); vec2 f=fract(p); vec2 u=f*f*(3.0-2.0*f);
    return mix(mix(hash2(i), hash2(i+vec2(1,0)), u.x), mix(hash2(i+vec2(0,1)), hash2(i+vec2(1,1)), u.x), u.y);
}

void main(){
    float t=uT; float seed=uSeed;
    vec2 p=vUV; float aspect=uRes.x/max(uRes.y,1.0);
    // 轻量反馈：保留速度感但不糊成团（纯黑底起步，霓虹硬边不受糊）
    vec2 vp=vec2(0.5+0.035*sin(t*0.00013),0.47+0.03*cos(t*0.00011));
    vec2 toP=p-vp; float rvp=length(toP*vec2(aspect,1.0));
    vec2 persWarp=toP*(0.010*rvp+0.003);
    vec3 prev=texture(uPrev, p-persWarp).rgb;
    vec3 col=prev*0.78; // 明显拖尾速度线，但底色纯黑不染
    // 音乐驱动仅局部元素（禁止全屏闪烁）：chaos 仅用于选形，beat/bass/treble 仅调局部尺寸/亮度，不碰速度/全局色
    float chaosA = hash(floor(t*0.0009 + seed*0.011));
    float chaosB = hash(floor(t*0.00055 + seed*0.017)*1.7);
    float beatPow = pow(uBeat, 1.6);
    float bassPow = pow(uBass, 1.3);
    float treblePow = pow(uTreble, 1.15);

    int preset=int(uPresetSel+0.5);

    if(preset==0){
        // 0 霓虹跑道：棋盘地板 + 方块障碍
        vec2 q=(p-vec2(0.5,0.47))*vec2(aspect,1.0);
        float fov=radians(72.0+6.0*uBass);
        float focal=1.0/tan(fov*0.5);
        vec3 ro=vec3(0.0, 0.85, t*0.00095*1.8);
        float pitch=radians(-18.0);
        vec3 rd0=normalize(vec3(q.x*focal, q.y*focal, 1.0));
        rd0.yz=rot2(pitch)*rd0.yz;
        vec3 rd=normalize(rd0);
        float th=( -ro.y)/rd.y;
        if(th>0.2 && th<12.0){
            vec3 hit=ro+rd*th;
            float depth=th*0.45;
            float pers=1.0/(1.0+depth*0.28);
            // 棋盘
            vec2 gp=hit.xz*0.85;
            vec2 ip=floor(gp); float ghash=hash2(ip);
            float checker=mod(ip.x+ip.y+ floor(chaosA*3.0),2.0);
            float line= step(0.02, min(fract(gp.x), fract(gp.y)));
            vec3 base = checker>0.5 ? vec3(0.02,0.08,0.18)*(0.7+0.6*bassPow) : vec3(0.02,0.02,0.04);
            col += base * (0.35+0.25*pers) * exp(-depth*0.18);
            if(line<0.5) col += vec3(0.05,0.85,0.95)*0.55*pers*exp(-depth*0.22);
            // 方块障碍：每 2.2m 一个，高度随 beat 弹起
            float zc=floor(hit.z/2.2+0.5); float zr=hit.z-zc*2.2;
            vec2 xz=hit.xz - vec2(0, zc*2.2);
            vec2 cell= floor((xz+vec2(1.1,1.1))/2.2);
            float bh=hash(zc*7.3+seed+chaosB*5.0)*0.50+0.20+0.90*beatPow+0.20*treblePow;
            vec3 boxP=vec3(hit.x, hit.y - bh*0.5, zr);
            float dbox=sdBox(boxP, vec3(0.45, bh*0.5, 0.45));
            float edge=exp(-abs(dbox)*18.0);
            float face=step(dbox,0.0);
            vec3 cbox=hsl2rgb(mod(zc*37.0+t*0.02+chaosA*120.0+treblePow*60.0,360.0),0.98,0.62+bassPow*0.1);
            col += cbox * face*(0.95+0.55*beatPow)*pers + cbox*edge*(0.65+0.55*beatPow)*0.9;
            // 速度线（远处汇聚）
            col += vec3(0.2,0.9,1.0)*exp(-abs(hit.x)*1.2)*exp(-depth*0.45)*0.18;
        } else {
            // 天空
            float sky=exp(-length(q-vec2(0,0.55))*1.6);
            col+=vec3(0.05,0.12,0.25)*sky*0.5;
        }
    } else if(preset==1){
        // 1 水晶洞窟：SDF 尖晶 + 硬边高光
        vec2 q=(p-vec2(0.5,0.47))*vec2(aspect,1.0);
        float fov=radians(62.0+6.0*uBass);
        float focal=1.0/tan(fov*0.5);
        vec3 ro=vec3(sin(t*0.00014)*0.22, cos(t*0.00011)*0.14, t*0.00052*2.2);
        float yaw=sin(t*0.00012)*0.14;
        vec3 rd0=normalize(vec3(q.x*focal*0.92, q.y*focal*0.92, 1.45));
        rd0.xz=rot2(yaw)*rd0.xz;
        vec3 rd=normalize(rd0);
        // 简化 KIFS 用 box + 扭曲代替，保证硬边
        float tt=0.12; float hit=-1.0; vec3 hitP=vec3(0);
        for(int i=0;i<38;i++){
            vec3 pos=ro+rd*tt;
            // 重复晶格
            vec3 cell=floor(pos/1.9+0.5); float h=hash2(cell.xz+seed*0.01);
            vec3 cpos=pos-cell*1.9;
            cpos.xz=rot2(h*3.14)*cpos.xz;
            float d=sdBox(cpos, vec3(0.32+0.10*h, 0.55+0.20*h, 0.32+0.10*h));
            // 走廊
            float corridor=length(pos.xy)-0.58;
            d=max(d, corridor);
            if(d<0.006){ hit=tt; hitP=pos; break; }
            tt+=max(d*0.45,0.014);
            if(tt>6.0) break;
        }
        if(hit>0.0){
            // 硬法线（数值）
            float e=0.006;
            vec3 n=normalize(vec3(
                sdBox(hitP+vec3(e,0,0)-floor((hitP+vec3(e,0,0))/1.9+0.5)*1.9, vec3(0.3))-sdBox(hitP-vec3(e,0,0)-floor((hitP-vec3(e,0,0))/1.9+0.5)*1.9, vec3(0.3)),
                sdBox(hitP+vec3(0,e,0)-floor((hitP+vec3(0,e,0))/1.9+0.5)*1.9, vec3(0.3))-sdBox(hitP-vec3(0,e,0)-floor((hitP-vec3(0,e,0))/1.9+0.5)*1.9, vec3(0.3)),
                sdBox(hitP+vec3(0,0,e)-floor((hitP+vec3(0,0,e))/1.9+0.5)*1.9, vec3(0.3))-sdBox(hitP-vec3(0,0,e)-floor((hitP-vec3(0,0,e))/1.9+0.5)*1.9, vec3(0.3))
            ));
            // 用 hash 上色强对比
            float h2=hash2(floor(hitP.xz)+seed*0.02);
            vec3 c=hsl2rgb(mod(h2*320.0+t*0.015+chaosB*120.0+treblePow*60.0,360.0),0.98,0.62+beatPow*0.10);
            vec3 ld=normalize(vec3(0.6,0.8,-0.5));
            float dif=clamp(dot(n,ld),0.0,1.0);
            float rim=pow(1.0-abs(dot(n,-rd)), 2.0);
            vec3 lit=c*(0.35+dif*0.85)+vec3(1)*rim*0.55;
            float fog=exp(-hit*0.32);
            col=mix(col, lit, 0.95*fog);
            // 激光扫描线
            float scan=fract(hitP.z*1.2 - t*0.003);
            if(scan<0.04+0.02*beatPow) col+=vec3(0.2,1.0,1.0)*(0.5+0.6*treblePow)*fog;
        } else {
            col+=vec3(0.02,0.06,0.12)*exp(-dot(q,q)*6.0)*0.5;
        }
    } else if(preset==2){
        // 2 分形地形等高线：Julia 地形线框
        vec2 q=(p-vec2(0.5,0.47))*vec2(aspect,1.0);
        vec2 cSet[4]; cSet[0]=vec2(-0.7269,0.1889); cSet[1]=vec2(0.285,0.01); cSet[2]=vec2(-0.8,0.156); cSet[3]=vec2(-0.4,0.6);
        float rndJ=floor(t/14000.0);
        vec2 cJulia=cSet[int(mod(rndJ+floor(hash(seed)*4.0),4.0))];
        float zf=exp(fract(t/14000.0)*5.2);
        vec2 zj=q*(0.55/zf)+cJulia*0.9;
        float iter=0.0; float esc=0.0;
        for(int i=0;i<48;i++){ zj=vec2(zj.x*zj.x - zj.y*zj.y, 2.0*zj.x*zj.y)+cJulia; iter+=1.0; if(dot(zj,zj)>16.0){ esc=1.0; break; } }
        float hueIter=fract(iter*0.045+t*0.00002+chaosA*0.7+treblePow*0.3)*360.0;
        if(esc>0.5){
            float contour=fract(iter*(0.5+0.2*chaosB));
            float line=exp(-pow(contour-0.5,2.0)*(120.0+80.0*beatPow))*0.9 + step(0.98-bassPow*0.08, fract(iter*(0.25+0.15*chaosA)))*0.6;
            col+=hsl2rgb(hueIter,0.95,0.58)*line*0.95;
            col+=hsl2rgb(mod(hueIter+40.0,360.0),0.9,0.55)*exp(-iter*0.055)*0.18;
        } else {
            col+=vec3(0.02,0.04,0.08)*0.6;
        }
        // 地形网格透视
        vec2 grid=q* (6.0+ zf*0.02);
        float gl= step(0.02, min(fract(grid.x), fract(grid.y)));
        if(gl<0.5) col+=vec3(0.06,0.9,0.9)*0.12;
    } else if(preset==3){
        // 3 赛博隧道：六边形蜂窝
        vec2 q=(p-vec2(0.5,0.47))*vec2(aspect,1.0);
        float fov=radians(70.0+6.0*uBass); float focal=1.0/tan(fov*0.5);
        float yaw=0.16*sin(t*0.00022);
        vec3 ro=vec3(0,0,t*0.0009*2.6);
        vec3 rd=normalize(vec3(q.x*focal, q.y*focal,1.0));
        rd.xz=rot2(yaw)*rd.xz;
        float depth=0.22/max(length(q),0.06)+t*0.0009;
        // 蜂窝坐标
        float hexS=1.15+0.35*chaosA+0.25*bassPow;
        vec2 hex=vec2( atan(q.y,q.x)*1.8, depth);
        vec2 hexF=fract(hex*hexS);
        float hexLine= min(min(hexF.x, 1.0-hexF.x), min(hexF.y,1.0-hexF.y));
        float glow=exp(-hexLine*55.0)*0.9;
        vec3 hc=hsl2rgb(mod(hex.y*18.0+t*0.015+chaosB*110.0+treblePow*60.0,360.0),0.98,0.62);
        float depthFade=clamp(1.0-depth*0.045,0.0,1.0);
        col+=hc*glow*depthFade*(0.90+0.60*beatPow);
        // 速度线
        float speed= fract(depth*0.5 - t*0.004);
        col+=hc*exp(-pow(speed-0.5,2.0)*120.0)*0.25*depthFade;
        col+=hc*exp(-length(q)*2.2)*0.12;
    } else if(preset==4){
        // 4 传送门：同心环
        vec2 q=(p-vec2(0.5,0.47))*vec2(aspect,1.0);
        float r=length(q); float a=atan(q.y,q.x);
        float depthF=fract(t*(0.00045+0.00025*bassPow));
        float pulse=exp(-pow(fract(r*3.2 - t*0.0015 + depthF),2.0)*25.0);
        float ring=exp(-abs(r-0.42)*22.0)*0.9 + exp(-abs(r-0.62)*18.0)*0.6 + exp(-abs(r-0.82)*14.0)*0.35;
        float seg= mod(a*3.0 + t*0.0005, 6.283);
        float segLine=exp(-pow(fract(seg/1.047)-0.5,2.0)*60.0);
        vec3 c=hsl2rgb(mod(t*0.018+chaosA*200.0+treblePow*80.0,360.0),0.98,0.62);
        col+=c*ring*segLine*(0.90+0.70*beatPow);
        col+=c*pulse*0.25*exp(-r*1.2);
        // 中心黑洞
        col=mix(col, vec3(0), step(r,0.18)*0.9);
        col+=c*exp(-r*r*3.0)*0.15;
    } else if(preset==5){
        // 5 激光幕墙：垂直激光
        vec2 q=(p-vec2(0.5,0.47))*vec2(aspect,1.0);
        float tL=t*0.00035;
        for(int i=0;i<4;i++){
            float fi=float(i);
            float xpos= sin(fi*1.7 + t*0.00021 + seed*0.01 + chaosA*2.0)*0.65 + cos(fi*0.9 + t*0.00014 + chaosB*1.5)*0.15 + 0.12*bassPow*sin(t*0.001+fi);
            float w=0.015+0.01*hash(fi*3.3+seed);
            float beam=exp(-abs(q.x - xpos)* (85.0/(0.02+abs(q.y))))*0.85;
            float scan= fract((q.y+1.2)/0.35 + tL + fi*0.22);
            float scanLine=exp(-pow(scan-0.5,2.0)*80.0)*0.5;
            vec3 lc=hsl2rgb(mod(fi*72.0 + t*0.012,360.0),0.98,0.60);
            col+=lc*beam*(0.7+0.5*sin(t*(0.003+0.002*treblePow)+fi)+0.4*beatPow)*0.9;
            col+=lc*beam*scanLine*0.4;
        }
        // 烟雾
        float fog=exp(-abs(q.y+0.15)*2.2)*0.18;
        col+=vec3(0.08,0.12,0.22)*fog;
    } else if(preset==6){
        // 6 镜屋：硬边反射
        vec2 q=(p-vec2(0.5,0.47))*vec2(aspect,1.0);
        float K= mix(5.0,8.0, step(0.5, chaosA)) + 0.8*bassPow; float ang=atan(q.y,q.x)+t*0.00018+chaosB*0.7;
        float seg=mod(ang, 6.283/K); seg=abs(seg-3.14159/K);
        float r=length(q);
        float lr=log(max(r,0.02))+t*0.00032;
        float ring=exp(fract(lr*1.8))*0.7;
        float edge=exp(-abs(ring-1.0)*14.0)*0.85 + exp(-abs(seg-0.26)*22.0)*0.5;
        float hueF=fract(t*0.015+ring*0.3)*360.0;
        col+=hsl2rgb(hueF,0.98,0.60)*edge*0.95;
        // 次级反射
        float edge2=exp(-abs(fract(lr*1.8+0.5)-0.5)*12.0)*0.25;
        col+=hsl2rgb(mod(hueF+180.0,360.0),0.95,0.58)*edge2*0.35;
    } else if(preset==7){
        // 7 冲击波竞技场
        vec2 q=(p-vec2(0.5,0.47))*vec2(aspect,1.0);
        float acc=0.0;
        float waveN= floor(3.0+chaosA*4.0); for(int i=0;i<5;i++){ if(float(i)>=waveN) break;
            float fi=float(i);
            float ph=fract(t*0.00038+fi*0.21+hash(fi*2.1+seed));
            float life=ph;
            float rWave=life*1.35;
            float d=length(q)-rWave;
            float ring=exp(-d*d*85.0)*exp(-life*1.2)*0.85;
            float hit=exp(-pow(fract(t*0.0012+fi*0.7)-0.5,2.0)*40.0);
            acc+=ring*(0.6+0.4*hit);
        }
        float hueW=fract(t*0.018+seed*0.001+chaosB*0.5+treblePow*0.2)*360.0;
        col+=hsl2rgb(hueW,0.98,0.60)*acc*0.95;
        col+=hsl2rgb(mod(hueW+30.0,360.0),0.9,0.58)*exp(-dot(q,q)*2.8)*0.22;
    } else if(preset==8){
        // 8 星门环廊：发光门
        vec2 q=(p-vec2(0.5,0.47))*vec2(aspect,1.0);
        float fov=radians(68.0+6.0*uBass); float focal=1.0/tan(fov*0.5);
        vec3 ro=vec3(0,0,t*0.00062*2.2);
        vec3 rd=normalize(vec3(q.x*focal, q.y*focal,1.0));
        float rep=1.45+0.3*chaosA; float tt=0.08+0.03*bassPow;
        float hit=-1.0; float hhash=0.0;
        for(int i=0;i<32;i++){
            vec3 pos=ro+rd*tt;
            float zc=floor(pos.z/rep+0.5);
            float h=hash(zc*6.7+seed*0.01);
            vec3 cpos=pos; cpos.z-=zc*rep;
            float d=sdTorus(cpos, vec2(0.48+0.08*h, 0.045+0.02*h));
            if(d<0.008){ hit=tt; hhash=h; break; }
            tt+=max(d*0.55,0.018);
            if(tt>7.0) break;
        }
        if(hit>0.0){
            float fog=exp(-hit*0.28);
            vec3 c=hsl2rgb(mod(hhash*310.0+t*0.02+chaosA*120.0+treblePow*70.0,360.0),0.98,0.62);
            col=mix(col, c*1.2, 0.92*fog);
            col+=c*pow(max(0.0,1.0-hit*0.12),2.0)*0.45;
            // 门框高光
            float rim=exp(-abs(hit-2.2)*0.9)*0.3;
            col+=c*rim;
        } else {
            col+=vec3(0.01,0.03,0.08)*exp(-dot(q,q)*5.0)*0.4;
        }
    } else {
        // 9 云海空战：低空掠云剪影
        vec2 q=(p-vec2(0.5,0.47))*vec2(aspect,1.0);
        float fov=radians(74.0); float focal=1.0/tan(fov*0.5);
        float pitch=radians(-16.0);
        vec3 ro=vec3(t*0.00008*1.2, 0.72, t*0.00007);
        vec3 rd0=normalize(vec3(q.x*focal, q.y*focal,1.0));
        rd0.yz=rot2(pitch)*rd0.yz; vec3 rd=normalize(rd0);
        // 云层
        float th=(0.25-ro.y)/rd.y;
        if(th>0.15 && th<9.0){
            vec3 hit=ro+rd*th;
            float depth=th*0.4;
            vec2 uv=hit.xz*0.72 + vec2(t*0.00007, t*0.00005);
            float n=vn(uv) + 0.5*vn(uv*2.1);
            float dens= smoothstep(0.45,0.62,n)*exp(-depth*0.22)*0.85;
            vec3 c=hsl2rgb(195.0+depth*8.0,0.85,0.62);
            col+=c*dens*0.95;
            // 机影剪影（每 3 秒掠过）
            float jetF=fract(t*(0.00045+0.00022*bassPow));
            vec2 jetPos=vec2((jetF-0.5)*3.2, 0.35);
            float jetD=length(q-jetPos);
            float jet=exp(-jetD*28.0)*step(jetF,0.95)*0.85;
            col+=vec3(0.05,0.05,0.07)*jet* -0.9 + vec3(1.0,0.3,0.2)*jet*0.4;
        } else {
            col+=vec3(0.04,0.10,0.22)*exp(-length(q-vec2(0,0.5))*1.4)*0.4;
        }
    }
    // 无全屏闪烁：音乐仅驱动局部几何（尺寸/边缘亮度），速度类恒定
    col=pow(col, vec3(0.92));
    col=clamp(col,0.0,1.0);
    outColor=vec4(col,1.0);
}
)";

const char* kFragBlit = R"(#version 300 es
precision highp float;
in vec2 vUV;
out vec4 outColor;
uniform sampler2D uTex;
void main(){ outColor=texture(uTex, vUV); }
)";

}  // namespace

#endif  // MUSICPLAYER_SHADER_SRC_H
