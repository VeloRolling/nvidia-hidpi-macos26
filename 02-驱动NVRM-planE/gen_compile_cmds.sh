#!/bin/bash
# 生成 OGKM Darwin 编译命令表（不做实际编译）
set -uo pipefail
OGKM=${OGKM:-$HOME/ogkm610}
SDK=$(xcrun --show-sdk-path)
KHDR="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
CCSTR="xcrun clang -arch x86_64 -fapple-kext -mkernel -nostdinc -I$KHDR -DNV_BSD -DNV_UNIX -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT"
python3 - "$OGKM" "$CCSTR" <<'PY'
import subprocess, re, os, sys
ogkm, cc = sys.argv[1], sys.argv[2]
for tree in ("src/nvidia", "src/nvidia-modeset"):
    d = os.path.join(ogkm, tree)
    outdir = os.path.join(d, "_out/Darwin_x86_64")
    os.makedirs(outdir, exist_ok=True)
    p = subprocess.run(["make", "-n", "-B", "TARGET_OS=Darwin", "TARGET_ARCH=x86_64", "CC=" + cc],
                       capture_output=True, text=True, cwd=d)
    lines = []
    for ln in p.stdout.splitlines():
        m = re.search(r'&&\s+(\S+)\s+(.*?)\s+-c\s+(\S+)\s+-o\s+(\S+)', ln)
        if not m:
            continue
        comp, flags, src, obj = m.groups()
        flags = re.sub(r'-MMD.*$', '', flags).strip()
        lines.append(f"{comp} {flags} -c {src} -o {obj}")
    with open(os.path.join(outdir, "compile_cmds.sh"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{tree}: {len(lines)} 条编译命令 -> {outdir}/compile_cmds.sh")
PY
