#!/bin/bash
# 构建 NVRM.kext：kext 侧 C++/C 源码 + NVKMS 归档 + RM 归档(libnvkernel.a)
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/nm_env.sh"
OUT=${1:-$HOME/nm-build/out}; SRC="$NMSRC/kexts/NVRM"
B="$OUT/NVRM.kext/Contents/MacOS"; mkdir -p "$B"
CXXFILES=(NVRM.cpp os-xnu.cpp os-xnu2.cpp nv_xnu_stubs.cpp os-nvkms-xnu.cpp
          nvrm_gpuva.cpp nvrm_surfshare.cpp nvrm_fbinfo.cpp nvkms_shaders.cpp nv_xnu_power.cpp)
objs=()
for n in "${CXXFILES[@]}"; do
  o="$OUT/nvrm-${n%.cpp}.o"
  xcrun clang++ "${KEXT_CXX[@]}" "${RMINC[@]}" "${KMSINC[@]}" -I"$SRC" -c "$SRC/$n" -o "$o" 2>"$o.err" \
    || { echo "❌ 编译失败: $n"; grep -m6 "error:" "$o.err"; exit 1; }
  objs+=("$o"); echo "✅ $n"
done
# nvrm_kapi_fields.c 要 NVKMS 的头，用 kext 侧参数编
o="$OUT/nvrm-nvrm_kapi_fields.o"
xcrun clang "${KEXT_CFLAGS[@]}" "${RMINC[@]}" "${KMSINC[@]}" -I"$SRC" -c "$SRC/nvrm_kapi_fields.c" -o "$o" 2>"$o.err" \
  || { echo "❌ 编译失败: nvrm_kapi_fields.c"; grep -m6 "error:" "$o.err"; exit 1; }
objs+=("$o"); echo "✅ nvrm_kapi_fields.c"
# nvrm_pageoff.c 是 RM 内部文件：用作者自己的 rmcc.py（RM 原生命令行）
o="$OUT/nvrm-nvrm_pageoff.o"
OGKM="$OGKM" python3 "$SRC/rmcc.py" "$SRC/nvrm_pageoff.c" "$o" 2>"$o.err" \
  || { echo "❌ 编译失败: nvrm_pageoff.c (rmcc.py)"; tail -6 "$o.err"; exit 1; }
objs+=("$o"); echo "✅ nvrm_pageoff.c (rmcc.py)"
echo "--- 链接：kext 对象 + libnvkms.a + libnvkernel.a ---"
xcrun clang++ "${KEXT_LD[@]}" "${objs[@]}" "$OGKM/libnvkms.a" "$OGKM/libnvkernel.a" -o "$B/NVRM" 2>"$OUT/nvrm-ld.err" \
  || { echo "❌ 链接失败"; grep -E "Undefined symbols|duplicate symbol|error:" "$OUT/nvrm-ld.err" | head -20; echo "..."; grep -A3 "Undefined symbols" "$OUT/nvrm-ld.err" | head -12; exit 2; }
cp "$SRC/Info.plist" "$OUT/NVRM.kext/Contents/Info.plist"
echo "✅ NVRM 链接成功: $(file -b "$B/NVRM")  $(stat -f %z "$B/NVRM") B"
