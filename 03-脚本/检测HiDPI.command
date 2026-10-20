#!/bin/bash
# 双击 = 检测当前显示状态；也可带参数切换分辨率，例如：
#   ./检测HiDPI.command 2560x1440
# 说明：这个驱动下 CGDisplayModeGetWidth 返回的是“像素”值，
#      判断 HiDPI 只能看系统报告的 “UI Looks like”（逻辑尺寸）< 像素尺寸。
/usr/bin/python3 - "$@" <<'PY'
import ctypes, subprocess, sys, re

cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
cg.CGMainDisplayID.restype = ctypes.c_uint32
disp = cg.CGMainDisplayID()
cg.CGDisplayCopyAllDisplayModes.restype = ctypes.c_void_p
cg.CGDisplayCopyAllDisplayModes.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
for f in ('CGDisplayModeGetWidth', 'CGDisplayModeGetHeight',
          'CGDisplayModeGetPixelWidth', 'CGDisplayModeGetPixelHeight'):
    getattr(cg, f).restype = ctypes.c_size_t
    getattr(cg, f).argtypes = [ctypes.c_void_p]
cf.CFArrayGetCount.restype = ctypes.c_long
cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
cg.CGDisplaySetDisplayMode.restype = ctypes.c_int32
cg.CGDisplaySetDisplayMode.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p]

arr = cg.CGDisplayCopyAllDisplayModes(disp, None)
modes = []
for i in range(cf.CFArrayGetCount(arr)):
    m = cf.CFArrayGetValueAtIndex(arr, i)
    modes.append((cg.CGDisplayModeGetPixelWidth(m), cg.CGDisplayModeGetPixelHeight(m), m))
modes.sort()

# 系统报告的当前状态（唯一可靠的 HiDPI 判据）
sp = subprocess.run(['system_profiler', 'SPDisplaysDataType'],
                    capture_output=True, text=True).stdout
res = re.search(r'Resolution: (\d+) x (\d+)', sp)
look = re.search(r'UI Looks like: (\d+) x (\d+)', sp)
print("当前状态")
print("  像素(物理渲染): %s x %s" % (res.group(1), res.group(2)) if res else "  像素: 未知")
print("  逻辑(界面尺寸): %s x %s" % (look.group(1), look.group(2)) if look else "  逻辑: 未知")
if res and look:
    if res.group(1) != look.group(1):
        print("  => HiDPI 已生效（2× 渲染，界面按 %sx%s 布局）" % (look.group(1), look.group(2)))
    else:
        print("  => 当前是 1:1 原生（未缩放）")

print("\n可用像素档位（共 %d）:" % len(modes))
for i, (pw, ph, m) in enumerate(modes, 1):
    print("  %2d) %4d x %-4d" % (i, pw, ph))

if len(sys.argv) > 1:
    want = sys.argv[1].lower().replace('*', 'x')
    try:
        w, h = [int(x) for x in want.split('x')]
    except Exception:
        print("\n参数格式应为 2560x1440"); sys.exit(1)
    hit = [m for pw, ph, m in modes if (pw, ph) == (w, h)]
    if not hit:
        print("\n找不到 %dx%d 档位" % (w, h)); sys.exit(1)
    rc = cg.CGDisplaySetDisplayMode(disp, hit[0], None)
    print("\n切换到 %dx%d -> 返回码 %d %s" % (w, h, rc, "(成功)" if rc == 0 else "(失败)"))
PY
echo
echo "按回车关闭。"
read -r _
