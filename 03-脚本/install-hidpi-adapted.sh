#!/bin/bash
# ============================================================
#  适配版 v3(本机版) — 2560×1440 内屏 HiDPI
#  面板: BOE NE156QHM-NY1  2560x1440 @165Hz (16:9)
#  标识: DisplayVendorID 0x9E5(2533) / DisplayProductID 0xA07(2567)
#
#  核心规则(实测得出):
#  1) scale-resolutions 条目 = 渲染缓冲尺寸(2×)，系统折半成逻辑尺寸
#     例: 3360x1890 -> 逻辑 1680x945（清晰）
#  2) 千万不要写等于面板原生的那条(2560x1440)：它会把原生 1:1 档顶掉，
#     导致只剩「逻辑 1280x720」，且无法切回原生
#  3) 高于 scanout 的缓冲(3520x1980 / 3840x2160)会被驱动拒绝，不要写
#
#  用法:
#    sudo bash install-hidpi-adapted.sh            # 安装
#    sudo bash install-hidpi-adapted.sh override   # 只重写 override
#    sudo bash install-hidpi-adapted.sh rollback   # 移除注入(只删本机 vendor 目录)
# ============================================================
set -u

VID_HEX="9e5"; PID_HEX="a07"
OVERRIDES="/Library/Displays/Contents/Resources/Overrides"
TARGET_DIR="$OVERRIDES/DisplayVendorID-$VID_HEX"
TARGET="$TARGET_DIR/DisplayProductID-$PID_HEX"
BOOTARGS_FLAG="nvfbhidpi=1"
MODE="${1:-install}"

say(){ echo -e "\n==> $*"; }

if [ "$MODE" = "rollback" ]; then
  say "移除注入（只删 $TARGET_DIR）"
  rm -rf "$TARGET_DIR"
  echo "    完成，重启后恢复原生模式列表"
  exit 0
fi

if [ "$MODE" != "override" ]; then
  say "步骤1/2 检查启动参数 $BOOTARGS_FLAG"
  cur="$(nvram boot-args 2>/dev/null | sed 's/^boot-args[[:space:]]*//')"
  if echo " $cur " | grep -q " $BOOTARGS_FLAG "; then
    echo "    NVRAM 已有 ✓"
  else
    echo "    NVRAM 没有 —— OpenCore 在 disk2s1 且会覆写 boot-args，"
    echo "    需写进 EFI/OC/config.plist 的 NVRAM->Add->boot-args，重启才生效"
  fi
fi

say "步骤2/2 生成 2× 缓冲 HiDPI 档（不含原生那条）"
TMP_DIR="$(mktemp -d)"
VID_HEX="$VID_HEX" PID_HEX="$PID_HEX" TMP_DIR="$TMP_DIR" /usr/bin/python3 <<'PY'
import os, plistlib, struct
vid = int(os.environ["VID_HEX"], 16)
pid = int(os.environ["PID_HEX"], 16)
tmp = os.environ["TMP_DIR"]
# 只放比面板原生(2560x1440)更大的缓冲，避免顶掉原生 1:1 档
raster = [(2880,1620),(3200,1800),(3360,1890)]
d = {
    "DisplayProductID": pid,
    "DisplayVendorID": vid,
    "DisplayProductName": "BOE NE156QHM-NY1",
    "scale-resolutions": [struct.pack(">III", w, h, 1) for w, h in raster],
    "target-default-ppmm": 10.0699301,
}
outdir = os.path.join(tmp, "DisplayVendorID-%x" % vid)
os.makedirs(outdir, exist_ok=True)
with open(os.path.join(outdir, "DisplayProductID-%x" % pid), "wb") as f:
    plistlib.dump(d, f)
for w, h in raster:
    print("    缓冲 %4dx%-4d -> 逻辑 %4dx%-4d" % (w, h, w//2, h//2))
PY

mkdir -p "$OVERRIDES"
rm -rf "$TARGET_DIR"
cp -R "$TMP_DIR/DisplayVendorID-$VID_HEX" "$OVERRIDES/"
chown -R root:wheel "$TARGET_DIR"; chmod 755 "$TARGET_DIR"; chmod 644 "$TARGET"
rm -rf "$TMP_DIR"
defaults write /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool YES

say "校验"
plutil -lint "$TARGET"
/usr/bin/python3 - "$TARGET" <<'PY'
import sys, plistlib, struct
d = plistlib.load(open(sys.argv[1], 'rb'))
print("    vid=0x%x pid=0x%x 共 %d 条" % (d['DisplayVendorID'], d['DisplayProductID'], len(d['scale-resolutions'])))
for raw in d['scale-resolutions']:
    w, h, f = struct.unpack('>III', raw)
    print("      缓冲 %dx%d flags=%d" % (w, h, f))
PY
echo "    boot-args: $(nvram boot-args)"

cat <<'EOT'

==========================================================
 写入完成，重启后：
   原生 1:1 (2560×1440) 仍在
   新增清晰档：1440×810 / 1600×900 / 1680×945
 回滚：sudo bash install-hidpi-adapted.sh rollback
==========================================================
EOT
