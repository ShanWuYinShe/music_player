#!/usr/bin/env bash
# music_app 一键签名构建安装脚本
#
# 用途：命令行完成「校验签名材料 → 构建 signed HAP → 安装到模拟器/真机」，
#       避免每次手动打开 DevEco Studio 生成签名。
#
# 签名材料生命周期：
#   - 由 DevEco Studio 自动签名（File > Project Structure > Signing Configs，
#     需登录华为账号）生成到 ~/.ohos/config/，并写入 music_app/build-profile.json5
#   - debug profile 有效期一年，期间本脚本全程命令行，无需打开 IDE
#   - 材料缺失/过期/设备未绑定 时，脚本打印指引，需要去 IDE 重新点一次自动签名
#
# 用法：
#   tools/auto_sign.sh            # 默认：校验+构建（不安装）
#   tools/auto_sign.sh install    # 校验+构建+安装到已连接设备
#   tools/auto_sign.sh -h         # 帮助

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/music_app"
BP="$APP_DIR/build-profile.json5"
CONFIG_DIR="$HOME/.ohos/config"
HDC="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
JAVA_HOME="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home"
NODE_BIN="/Applications/DevEco-Studio.app/Contents/tools/node/bin"
HVIGOR_BIN="/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin"
SIGNED_HAP="$APP_DIR/entry/build/default/outputs/default/entry-default-signed.hap"

DO_INSTALL=0
if [[ $# -gt 0 ]]; then
  case "$1" in
    install) DO_INSTALL=1 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "未知参数: $1（支持 install）" >&2; exit 2 ;;
  esac
fi

log()  { printf '\033[1;32m[auto_sign]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[auto_sign]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[auto_sign]\033[0m %s\n' "$*" >&2; exit 1; }

GUIDE() {
  cat <<'EOF'

┌─────────────────────────────────────────────────────────────────┐
│  需要打开 DevEco Studio 重新生成签名（仅此一步需要 GUI）：       │
│  1. 打开工程 music_app，连接设备/启动模拟器                      │
│  2. File > Project Structure > Signing Configs                  │
│  3. 勾选 "Automatically generate signature"，登录账号，点 OK     │
│  4. 关掉 DevEco 后重跑本脚本即可                                │
└─────────────────────────────────────────────────────────────────┘
EOF
}

# ---------- 1. 读取 build-profile.json5 中的签名材料路径 ----------
if [[ ! -f "$BP" ]]; then
  die "找不到 ${BP}"
fi

read_material() {
  # $1: JSON5 键名；输出值（去引号）。用 node 解析 JSON5。
  "$NODE_BIN/node" -e '
    const fs = require("fs");
    let src = fs.readFileSync(process.argv[1], "utf8");
    // JSON5 宽松解析：去掉尾逗号
    src = src.replace(/,(\s*[}\]])/g, "$1");
    const j = JSON.parse(src);
    const s = j.app.signingConfigs[0].material;
    console.log(s[process.argv[2]] || "");
  ' "$BP" "$1"
}

CERT="$(read_material certpath)"
PROFILE="$(read_material profile)"
STORE="$(read_material storeFile)"
if [[ -z "$CERT" || -z "$PROFILE" || -z "$STORE" ]]; then
  die "build-profile.json5 中 signingConfigs.material 缺少 certpath/profile/storeFile"
fi

# ---------- 2. 校验材料文件存在 ----------
for f in "$CERT" "$PROFILE" "$STORE"; do
  if [[ ! -f "$f" ]]; then
    warn "签名材料缺失: $f"
    GUIDE
    exit 1
  fi
done
log "签名材料就位（p12/cer/p7b）"

# ---------- 3. 校验 profile 有效期 ----------
PARSE="$(dirname "${BASH_SOURCE[0]}")/parse_profile.py"
if [[ -f "$PROFILE" ]]; then
  PY_OUT="$(python3 "$PARSE" "$PROFILE" 2>/dev/null || true)"
  if [[ -z "$PY_OUT" ]]; then
    warn "无法解析 profile ${PROFILE}，建议去 IDE 重新生成签名"
    GUIDE
    exit 1
  fi
  NB="$(echo "$PY_OUT" | cut -d' ' -f1)"
  NA="$(echo "$PY_OUT" | cut -d' ' -f2)"
  NDEV="$(echo "$PY_OUT" | cut -d' ' -f3)"
  TODAY="$(date +%Y-%m-%d)"
  if [[ "$TODAY" < "$NA" ]]; then
    log "profile 有效（${NB} ~ ${NA}，绑定 ${NDEV} 台设备）"
  else
    warn "profile 已过期（${NB} ~ ${NA}），需要重新生成签名"
    GUIDE
    exit 1
  fi
fi

# ---------- 4. （install 模式）校验当前设备已绑定 ----------
if [[ "$DO_INSTALL" -eq 1 ]]; then
  # 序列号可含字母开头（如 MJE0224A…），仅排除空输出与 [Empty] 占位
  TARGETS="$("$HDC" list targets 2>/dev/null | grep -E '^[0-9A-Za-z]' || true)"
  if [[ -z "$TARGETS" ]]; then
    die "没有已连接的设备/模拟器，请先启动（Emulator -start <name>）"
  fi
  # 本地模拟器无需 profile 设备绑定（实测未绑定也能安装成功，预检按真机
  # 规则校验只会误报拦人），跳过
  if [[ "$(echo "$TARGETS" | wc -l | tr -d ' ')" -eq 1 && "$TARGETS" == 127.0.0.1:* ]]; then
    log "本地模拟器（${TARGETS}），跳过设备绑定校验"
  else
    UDID="$("$HDC" shell bm get -u 2>/dev/null | grep -oE '[0-9A-F]{64}' | head -1 || true)"
    if [[ -z "$UDID" ]]; then
      warn "无法读取设备 UDID，跳过设备绑定校验"
    elif ! python3 "$PARSE" "$PROFILE" "$UDID" 2>/dev/null; then
      warn "当前设备（${UDID}）未绑定到 profile，安装会失败"
      warn "请在 IDE 中连接该设备后重新自动签名（会把设备加入绑定列表）"
      GUIDE
      exit 1
    else
      log "设备已绑定（${UDID}）"
    fi
  fi
fi

# ---------- 5. 构建 signed HAP ----------
export DEVECO_SDK_HOME JAVA_HOME
export PATH="$NODE_BIN:$HVIGOR_BIN:$PATH"
log "构建 signed HAP（hvigorw assembleHap）..."
(
  cd "$APP_DIR"
  hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon 2>&1 \
    | grep -E "BUILD|ERROR|error|SignHap|WARN: File" | tail -20
)
if [[ ! -f "$SIGNED_HAP" ]]; then
  die "构建未产出 ${SIGNED_HAP}"
fi
log "构建成功: ${SIGNED_HAP}"

# ---------- 6. 安装（install 模式） ----------
if [[ "$DO_INSTALL" -eq 1 ]]; then
  log "安装到设备..."
  "$HDC" install -r "$SIGNED_HAP" >/dev/null 2>&1 \
    || die "hdc install 失败（可能设备未解锁/签名不匹配）"
  log "安装成功，启动应用..."
  "$HDC" shell aa start -a EntryAbility -b com.lsyb.musicplayer
  log "已启动 com.lsyb.musicplayer"
fi

log "完成"
