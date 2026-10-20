#!/bin/bash
# =============================================================================
#  升级NVRM.command —— 换新版 NVIDIA 驱动时，保留 2× HiDPI 缩放能力
# -----------------------------------------------------------------------------
#  做什么：
#    1. 备份现役 NVRM / NVRMFB / AuxKC 到桌面
#    2. 把 planE 补丁打到新版 open-gpu-kernel-modules 源码
#    3. 编译 → 归档 → 重链接 → 写 AuxKC
#    4. 校验 kext 确实进了 AuxKC，确认后才让你重启
#  不做：不动 NVAccel / NVRMAGDC / NVRMFB 的 hidpi 视口逻辑以外的部分
#
#  用法：双击运行；或 ./升级NVRM.command /路径/到/open-gpu-kernel-modules
# =============================================================================
set -uo pipefail

CHECK_ONLY=0
if [[ "${1:-}" == "--check" ]]; then CHECK_ONLY=1; shift; fi

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_FILE="$SELF_DIR/planE-核心改动.diff"
NM_SRC="${NMSRC:-$HOME/nvdrv-src}"
KE_DIR="/Library/Extensions"
AUX_KC="/Library/KernelCollections/AuxiliaryKernelExtensions.kc"
BOOT_KC="/System/Library/KernelCollections/BootKernelExtensions.kc"
SYS_KC="/System/Library/KernelCollections/SystemKernelExtensions.kc"
STAMP="$(date +%Y%m%d-%H%M%S)"
BAK_DIR="$HOME/Desktop/NVRM升级备份-$STAMP"
OUT_DIR="$HOME/nvbuild-out-$STAMP"
LOG="$BAK_DIR/upgrade.log"

c_ok()   { printf "\033[32m%s\033[0m\n" "$*"; }
c_err()  { printf "\033[31m%s\033[0m\n" "$*"; }
c_warn() { printf "\033[33m%s\033[0m\n" "$*"; }
c_hdr()  { printf "\n\033[1;36m━━━ %s ━━━\033[0m\n" "$*"; }
die()    { c_err "❌ $*"; c_err "日志：$LOG"; exit 1; }
ask()    { local a; printf "\033[33m%s [y/N] \033[0m" "$1"; read -r a; [[ "$a" == y || "$a" == Y ]]; }

# 把所有输出同时写进日志
if [[ $CHECK_ONLY -eq 1 ]]; then
  LOG="/tmp/升级NVRM-check-$STAMP.log"
else
  mkdir -p "$BAK_DIR"
fi
exec > >(tee -a "$LOG") 2>&1

clear
cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║   NVIDIA 驱动升级助手（保留 2× HiDPI 缩放）                  ║
║   全程 5~15 分钟，最后一步才动系统                            ║
╚══════════════════════════════════════════════════════════════╝
BANNER

# ────────────────────────────────────────────────────────────
c_hdr "阶段 0/7  环境自检"
[[ $EUID -eq 0 ]] && die "请不要用 sudo 启动本脚本，脚本内部会自己提权"
c_ok "✓ 非 root 运行"

xcrun --find clang >/dev/null 2>&1 || die "缺少 Xcode Command Line Tools，请先运行：xcode-select --install"
c_ok "✓ clang: $(xcrun --find clang)"
command -v python3 >/dev/null || die "找不到 python3"
command -v libtool >/dev/null || die "找不到 libtool"
c_ok "✓ python3 / libtool 就位"

[[ -f /System/Library/Kernels/kernel ]] || die "找不到 /System/Library/Kernels/kernel"
[[ -f "$BOOT_KC" && -f "$SYS_KC" ]] || die "找不到系统 KC，无法重建 AuxKC"
[[ -d "$KE_DIR/NVRM.kext" ]] || die "找不到 $KE_DIR/NVRM.kext"
[[ -f "$NM_SRC/kexts/NVRM/rmcc.py" ]] || die "找不到作者驱动仓库：$NM_SRC（可用 NMSRC=... 指定）"
[[ -f "$PATCH_FILE" ]] || die "缺少补丁文件：$PATCH_FILE"
c_ok "✓ 系统 KC / 现役 kext / 作者仓库 / 补丁文件 齐全"

AVAIL=$(df -g / | awk 'NR==2{print $4}')
[[ "${AVAIL:-99}" -ge 5 ]] || c_warn "⚠ 根分区剩余 ${AVAIL}GB，编译建议 ≥5GB 空闲"

if csrutil status | grep -q "Kext Signing: disabled"; then
  c_ok "✓ SIP: Kext Signing 已关闭"
else
  c_warn "⚠ SIP 的 Kext Signing 未关闭，新 kext 可能无法进入 AuxKC"
  ask "仍然继续？" || exit 1
fi

if pgrep -qx WindowServer && [[ -n "${SSH_TTY:-}" ]]; then
  c_warn "⚠ 检测到远程会话，安装后图形界面可能中断"
fi

# ────────────────────────────────────────────────────────────
c_hdr "阶段 1/7  选择新版驱动源码"

OGKM="${1:-}"
if [[ -z "$OGKM" ]]; then
  echo "把新版 open-gpu-kernel-modules 源码目录拖进本窗口，然后回车："
  printf "> "; read -r OGKM
fi
OGKM="${OGKM%\'}"; OGKM="${OGKM#\'}"; OGKM="${OGKM%/}"
OGKM="${OGKM/#\~/$HOME}"

KAPI="$OGKM/src/nvidia-modeset/kapi/src/nvkms-kapi.c"
[[ -f "$KAPI" ]] || die "这不是有效的 OGKM 源码树（缺 $KAPI）"
NEWVER=$(grep -m1 -E "^NVIDIA_VERSION" "$OGKM/version.mk" 2>/dev/null | sed 's/.*=\s*//')
NEWVER="${NEWVER:-未知版本}"
c_ok "✓ 源码树：$OGKM"
c_ok "✓ 版本：$NEWVER"
echo "  当前安装：$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$KE_DIR/NVRM.kext/Contents/Info.plist" 2>/dev/null || echo '?')  (nullmoth)"

if [[ -f "$OGKM/libnvkms.a" ]]; then
  c_warn "⚠ 该树里已有旧的 libnvkms.a / libnvkernel.a，将被本次编译结果覆盖"
fi

# 作者仓库源文件列表 vs 构建脚本里的列表
LISTED=$(sed -n '/^CXXFILES=/,/)$/p' "$SELF_DIR/build_nvrm2.sh" | tr -d '\\\n' | grep -oE '[A-Za-z0-9_.-]+\.cpp' | sort -u)
ACTUAL=$(find "$NM_SRC/kexts/NVRM" -maxdepth 1 -name '*.cpp' -exec basename {} \; | sort -u)
if [[ "$LISTED" != "$ACTUAL" ]]; then
  c_warn "⚠ 作者仓库的源文件与 build_nvrm2.sh 的 CXXFILES 列表不一致："
  diff <(echo "$LISTED") <(echo "$ACTUAL") | sed 's/^</  仅脚本列出: /; s/^>/  仅仓库存在: /'
  c_warn "  请先在 build_nvrm2.sh 里同步 CXXFILES，再重跑本脚本"
  die "构建清单不同步，已中止（未做任何改动）"
fi
c_ok "✓ 源文件清单与构建脚本一致（$(echo "$ACTUAL" | wc -l | tr -d ' ') 个 .cpp）"

# ────────────────────────────────────────────────────────────
if [[ $CHECK_ONLY -eq 1 ]]; then
  c_hdr "补丁兼容性检查（--check 模式）"
  if grep -q gNvkmsAllowHeadSurfaceOverride "$KAPI"; then
    c_ok "✓ 源码里已经含 planE 补丁"
  elif ( cd "$OGKM" && patch -p1 --dry-run --batch -i "$PATCH_FILE" > /tmp/planE-chk.$$ 2>&1 ); then
    c_ok "✓ 补丁可以干净地应用到这份源码"
  else
    c_warn "⚠ 补丁无法自动应用，需要手工合并以下位置："
    grep -E "FAILED|Hunk|Reversed|saving rejects" /tmp/planE-chk.$$ | sed 's/^/    /'
    c_warn "  参考改动见 planE-核心改动.diff（4 处，注释含 planE / NMRDIAG）"
  fi
  rm -f /tmp/planE-chk.$$
  c_hdr "自检结束（未改动任何文件）"
  echo "  已检查：Xcode / SDK / 系统 KC / 现役 kext / 作者仓库 / 源文件清单 / 补丁兼容性"
  echo "  一切就绪后，双击本脚本（不带 --check）即可开始升级。"
  exit 0
fi

# ────────────────────────────────────────────────────────────
c_hdr "阶段 2/7  备份现役驱动"
sudo -v || die "无法获得管理员权限"
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null' EXIT

sudo cp -R "$KE_DIR/NVRM.kext"   "$BAK_DIR/NVRM.kext.bak"    || die "备份 NVRM 失败"
[[ -d "$KE_DIR/NVRMFB.kext" ]] && sudo cp -R "$KE_DIR/NVRMFB.kext" "$BAK_DIR/NVRMFB.kext.bak"
[[ -f "$AUX_KC" ]] && sudo cp "$AUX_KC" "$BAK_DIR/AuxiliaryKernelExtensions.kc.bak"
system_profiler SPDisplaysDataType > "$BAK_DIR/显示状态-升级前.txt" 2>/dev/null
kmutil showloaded --list-only --arch x86_64 2>/dev/null | grep -i nullmoth > "$BAK_DIR/已加载kext-升级前.txt"
nvram boot-args > "$BAK_DIR/boot-args.txt" 2>/dev/null
c_ok "✓ 已备份到：$BAK_DIR"
ls -1 "$BAK_DIR" | sed 's/^/    /'

# ────────────────────────────────────────────────────────────
c_hdr "阶段 3/7  打 planE 补丁"
if grep -q gNvkmsAllowHeadSurfaceOverride "$KAPI"; then
  c_ok "✓ 该源码已含 planE 标记，跳过"
else
  if ( cd "$OGKM" && patch -p1 --dry-run --batch -i "$PATCH_FILE" > /tmp/planE-dry.$$ 2>&1 ); then
    c_ok "✓ 试打成功，正式应用"
    ( cd "$OGKM" && patch -p1 --batch -i "$PATCH_FILE" ) || die "补丁应用失败"
    grep -q gNvkmsAllowHeadSurfaceOverride "$KAPI" || die "补丁似乎没有生效"
    c_ok "✓ planE 补丁已应用（3 处逻辑 + 1 处诊断日志）"
  else
    c_err "✗ 补丁与新源码不匹配，无法自动应用。试打输出："
    sed 's/^/    /' /tmp/planE-dry.$$; rm -f /tmp/planE-dry.$$
    cat <<EOF

新版 nvkms-kapi.c 结构变了，需要手工合并。要改的 4 处（参考文件里的注释都带 planE / NMRDIAG）：
  1. 文件头：新增 int gNvkmsAllowHeadSurfaceOverride = 2;
  2. NvKmsKapiMainLayerConfigToKms()：图层 sizeOut 用 srcWidth/srcHeight（不缩放）
  3. NvKmsKapiRequestedModeSetConfigToKms()：paramsHead->viewPortSizeIn 用桌面尺寸
  4. 同函数末尾：set mode ioctl 失败时补一行 nvkms_log 诊断
参考实现：$SELF_DIR/../02-驱动NVRM-planE/nvkms-kapi.planE.c（若存在）
或 $HOME/nvrecipe/nvkms-kapi.stock-orig.c 对照

手工改完后**重跑本脚本**，它会识别已含标记并继续往下走。
EOF
    die "补丁不匹配，已停在编译之前（系统未改动）"
  fi
fi

# ────────────────────────────────────────────────────────────
c_hdr "阶段 4/7  生成编译命令表"
export OGKM
( cd "$OGKM" && bash "$SELF_DIR/gen_compile_cmds.sh" ) || die "生成编译命令表失败"
N1=$(wc -l < "$OGKM/src/nvidia/_out/Darwin_x86_64/compile_cmds.sh" 2>/dev/null | tr -d ' ')
N2=$(wc -l < "$OGKM/src/nvidia-modeset/_out/Darwin_x86_64/compile_cmds.sh" 2>/dev/null | tr -d ' ')
N1=${N1:-0}; N2=${N2:-0}
c_ok "  nvidia=$N1 条，nvidia-modeset=$N2 条"
[[ "$N1" -gt 100 && "$N2" -gt 50 ]] || die "命令表条数异常，新版 Makefile 结构可能变了（看 $OGKM/src/*/_out）"

# ────────────────────────────────────────────────────────────
c_hdr "阶段 5/7  编译（$(sysctl -n hw.ncpu) 线程，约 3~8 分钟，可去喝口水）"
OGKM="$OGKM" WORKERS="$(sysctl -n hw.ncpu)" python3 "$SELF_DIR/build_ogkm.py" \
  || die "有对象编译失败，见 $OGKM/_buildlogs/*-fails.log（系统未改动）"

c_ok "✓ 编译完成，归档静态库"
libtool -static -o "$OGKM/libnvkernel.a" "$OGKM"/src/nvidia/_out/Darwin_x86_64/*.o \
  || die "归档 libnvkernel.a 失败"
libtool -static -o "$OGKM/libnvkms.a" "$OGKM"/src/nvidia-modeset/_out/Darwin_x86_64/*.o \
  || die "归档 libnvkms.a 失败"
c_ok "  libnvkernel.a $(du -h "$OGKM/libnvkernel.a" | cut -f1)，libnvkms.a $(du -h "$OGKM/libnvkms.a" | cut -f1)"

# ────────────────────────────────────────────────────────────
c_hdr "阶段 6/7  重链接 kext"
mkdir -p "$OUT_DIR"
OGKM="$OGKM" NMSRC="$NM_SRC" bash "$SELF_DIR/build_nvrm2.sh" "$OUT_DIR" \
  || die "NVRM 链接失败（系统未改动）"

BUILD_FB=0
if [[ -d "$KE_DIR/NVRMFB.kext" ]]; then
  if ask "同时重建 NVRMFB（帧缓冲，含 hidpi 视口逻辑）？"; then BUILD_FB=1; fi
fi
if [[ $BUILD_FB -eq 1 ]]; then
  OGKM="$OGKM" NMSRC="$NM_SRC" bash "$SELF_DIR/build_nvrmfb.sh" "$OUT_DIR" \
    || die "NVRMFB 编译失败（系统未改动）"
fi

# ad-hoc 签名：未签名 kext 在 Kext Signing 关闭时也能加载，但签了更稳
codesign -f -s - "$OUT_DIR/NVRM.kext" 2>/dev/null && c_ok "✓ NVRM.kext 已 ad-hoc 签名"
[[ $BUILD_FB -eq 1 ]] && codesign -f -s - "$OUT_DIR/NVRMFB.kext" 2>/dev/null && c_ok "✓ NVRMFB.kext 已 ad-hoc 签名"

c_ok "✓ 产物：$OUT_DIR"

# ────────────────────────────────────────────────────────────
c_hdr "阶段 7/7  安装并重建 AuxKC"
echo "即将覆盖：$KE_DIR/NVRM.kext$([[ $BUILD_FB -eq 1 ]] && echo ' 和 NVRMFB.kext')"
echo "备份在：  $BAK_DIR"
ask "确认写入系统？" || { c_warn "已取消，产物保留在 $OUT_DIR"; exit 0; }

sudo ditto "$OUT_DIR/NVRM.kext" "$KE_DIR/NVRM.kext" || die "拷贝 NVRM.kext 失败"
[[ $BUILD_FB -eq 1 ]] && sudo ditto "$OUT_DIR/NVRMFB.kext" "$KE_DIR/NVRMFB.kext"
# ★ 陷阱 1：ditto 保留源属主，非 root 属主的 kext 会被 kmutil 静默排除
sudo chown -R root:wheel "$KE_DIR/NVRM.kext"
sudo chmod -R go-w "$KE_DIR/NVRM.kext"
[[ $BUILD_FB -eq 1 ]] && { sudo chown -R root:wheel "$KE_DIR/NVRMFB.kext"; sudo chmod -R go-w "$KE_DIR/NVRMFB.kext"; }
c_ok "✓ 已安装并修正属主 root:wheel"

c_ok "重建 AuxKC（约 30~90 秒）"
sudo rm -f /tmp/AuxKC.new
sudo kmutil create -n aux --volume-root / --allow-missing-kdk \
  --kernel /System/Library/Kernels/kernel \
  -B "$BOOT_KC" -S "$SYS_KC" \
  --repository /Library/Extensions \
  -A /tmp/AuxKC.new -z || die "kmutil create 失败，系统仍用旧 AuxKC"

# ★ 陷阱 2：必须确认 nullmoth 的 kext 真在包里，否则重启会黑屏/无加速
FOUND=$(sudo kmutil inspect -a x86_64 -A /tmp/AuxKC.new 2>/dev/null | grep -c "com.nullmoth.NVRM")
FOUND_FB=$(sudo kmutil inspect -a x86_64 -A /tmp/AuxKC.new 2>/dev/null | grep -c "com.nullmoth.NVRMFB")
echo "  新 AuxKC 内：NVRM=$FOUND  NVRMFB=$FOUND_FB"

if [[ "$FOUND" -lt 1 ]] || { [[ $BUILD_FB -eq 1 ]] && [[ "$FOUND_FB" -lt 1 ]]; }; then
  c_err "✗ 新 AuxKC 里缺少 com.nullmoth 的 kext，这次安装已放弃"
  c_err "  常见原因：kext 属主不是 root:wheel、Info.plist 依赖不满足、签名被拒"
  if [[ -f "$BAK_DIR/AuxiliaryKernelExtensions.kc.bak" ]]; then
    sudo cp "$BAK_DIR/AuxiliaryKernelExtensions.kc.bak" "$AUX_KC"
    c_warn "  已自动还原旧 AuxKC"
  fi
  # kext 目录也要还原，否则下次 kmutil create 会把新版又带进去
  if [[ -d "$BAK_DIR/NVRM.kext.bak" ]]; then
    sudo rm -rf "$KE_DIR/NVRM.kext"
    sudo cp -R "$BAK_DIR/NVRM.kext.bak" "$KE_DIR/NVRM.kext"
    sudo chown -R root:wheel "$KE_DIR/NVRM.kext"
    c_warn "  已还原旧 NVRM.kext"
  fi
  if [[ $BUILD_FB -eq 1 && -d "$BAK_DIR/NVRMFB.kext.bak" ]]; then
    sudo rm -rf "$KE_DIR/NVRMFB.kext"
    sudo cp -R "$BAK_DIR/NVRMFB.kext.bak" "$KE_DIR/NVRMFB.kext"
    sudo chown -R root:wheel "$KE_DIR/NVRMFB.kext"
    c_warn "  已还原旧 NVRMFB.kext"
  fi
  rm -f /tmp/AuxKC.new
  die "未生效，未重启（系统已恢复原状）"
fi

sudo mv -f /tmp/AuxKC.new "$AUX_KC" || die "替换 AuxKC 失败"
sudo chown root:wheel "$AUX_KC"; sudo chmod 644 "$AUX_KC"
c_ok "✓ AuxKC 已更新（$(du -h "$AUX_KC" | cut -f1)）"

# ────────────────────────────────────────────────────────────
c_hdr "完成"
cat <<EOF
  驱动版本： $NEWVER
  备份位置： $BAK_DIR
  构建产物： $OUT_DIR

  重启后请立即验证（两行必须是 2:1）：
      system_profiler SPDisplaysDataType | grep -E "Resolution|UI Looks like"

  出问题时：
     ./03-脚本/回滚NVRM.command      ← 恢复 2.4.3 旧驱动
     恢复模式删掉 AuxKC 可回到无加速的安全状态

EOF
if ask "现在重启？"; then
  sudo reboot
else
  c_warn "已取消重启。下次开机会加载新驱动。"
fi
