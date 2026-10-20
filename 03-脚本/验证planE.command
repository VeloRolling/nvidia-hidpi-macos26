#!/bin/bash
# 验证 planE 是否生效：切换缩放档 + 读驱动判定结果
set -uo pipefail
clear
echo "=================================================="
echo " planE 生效验证"
echo "=================================================="
echo
echo "【1】当前显示状态"
system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Resolution|UI Looks like|Refresh Rate|Main Display" | sed 's/^ */   /'
echo
echo "【2】可用模式（像素 / 逻辑）"
/usr/bin/python3 - <<'PY'
import ctypes
cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
cg.CGMainDisplayID.restype = ctypes.c_uint32
d = cg.CGMainDisplayID()
cg.CGDisplayCopyAllDisplayModes.restype = ctypes.c_void_p
cg.CGDisplayCopyAllDisplayModes.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
for f in ('CGDisplayModeGetWidth','CGDisplayModeGetHeight','CGDisplayModeGetPixelWidth','CGDisplayModeGetPixelHeight'):
    getattr(cg,f).restype = ctypes.c_size_t; getattr(cg,f).argtypes=[ctypes.c_void_p]
cg.CGDisplayModeGetRefreshRate.restype = ctypes.c_double
cg.CGDisplayModeGetRefreshRate.argtypes = [ctypes.c_void_p]
cf.CFArrayGetCount.restype = ctypes.c_long; cf.CFArrayGetCount.argtypes=[ctypes.c_void_p]
cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p; cf.CFArrayGetValueAtIndex.argtypes=[ctypes.c_void_p, ctypes.c_long]
a = cg.CGDisplayCopyAllDisplayModes(d, None)
rows = set()
for i in range(cf.CFArrayGetCount(a)):
    m = cf.CFArrayGetValueAtIndex(a, i)
    rows.add((cg.CGDisplayModeGetWidth(m), cg.CGDisplayModeGetHeight(m),
              cg.CGDisplayModeGetPixelWidth(m), cg.CGDisplayModeGetPixelHeight(m),
              round(cg.CGDisplayModeGetRefreshRate(m))))
for r in sorted(rows, reverse=True):
    print("   %4dx%-4d  px %4dx%-4d  %3dHz" % (r[0],r[1],r[2],r[3],r[4]))
PY
echo
echo "【3】实际切一次 3360x1890（1680x945 的 2 倍缓冲），看是否真生效"
sudo /usr/bin/python3 - <<'PY'
import ctypes, subprocess, time
cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
cg.CGMainDisplayID.restype = ctypes.c_uint32
d = cg.CGMainDisplayID()
cg.CGDisplayCopyAllDisplayModes.restype = ctypes.c_void_p
cg.CGDisplayCopyAllDisplayModes.argtypes=[ctypes.c_uint32, ctypes.c_void_p]
for f in ('CGDisplayModeGetWidth','CGDisplayModeGetHeight','CGDisplayModeGetPixelWidth','CGDisplayModeGetPixelHeight'):
    getattr(cg,f).restype = ctypes.c_size_t; getattr(cg,f).argtypes=[ctypes.c_void_p]
cg.CGDisplayModeGetRefreshRate.restype = ctypes.c_double
cg.CGDisplayModeGetRefreshRate.argtypes=[ctypes.c_void_p]
cf.CFArrayGetCount.restype = ctypes.c_long; cf.CFArrayGetCount.argtypes=[ctypes.c_void_p]
cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p; cf.CFArrayGetValueAtIndex.argtypes=[ctypes.c_void_p, ctypes.c_long]
cg.CGDisplaySetDisplayMode.restype = ctypes.c_int32
cg.CGDisplaySetDisplayMode.argtypes=[ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p]
a = cg.CGDisplayCopyAllDisplayModes(d, None)
target = None
for i in range(cf.CFArrayGetCount(a)):
    m = cf.CFArrayGetValueAtIndex(a, i)
    if (cg.CGDisplayModeGetWidth(m), cg.CGDisplayModeGetHeight(m)) == (3360, 1890):
        target = m
        if abs(cg.CGDisplayModeGetRefreshRate(m) - 165) < 1: break
if target is None:
    print("   模式列表里没有 3360x1890")
else:
    print("   SetDisplayMode rc =", cg.CGDisplaySetDisplayMode(d, target, None))
    time.sleep(3)
out = subprocess.run(["system_profiler","SPDisplaysDataType"],capture_output=True,text=True).stdout
for line in out.splitlines():
    s = line.strip()
    if s.startswith(("Resolution:","UI Looks like:")):
        print("  ", s)
PY
echo
echo "【4】驱动日志（最近的模式设置判定）"
sudo dmesg 2>/dev/null | grep -iE "switchMode|set mode (refused|ioctl FAILED)" | tail -8 | sed 's/^/   /'
echo
echo "提示：想要 1680x945 就选上面列出的 3360x1890 那一档；"
echo "      若日志里 test/COMMIT 都是 -> 1，说明 planE 生效。"
echo
read -r -p "按回车关闭..." _
