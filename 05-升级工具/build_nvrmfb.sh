#!/bin/bash
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/nm_env.sh"
OUT=${1:-$HOME/nm-build/out}; SRC="$NMSRC/kexts/NVRMFB"
mkdir -p "$OUT/NVRMFB.kext/Contents/MacOS"
set -x
xcrun clang++ "${KEXT_CXX[@]}" "${RMINC[@]}" "${KMSINC[@]}" -I"$SRC" -I"$SRC/fb" \
  -c "$SRC/fb/nvrm-fb.cpp" -o "$OUT/nvrm-fb.o" 2>"$OUT/nvrmfb-cc.err" || { grep "error:" "$OUT/nvrmfb-cc.err" | head -15; exit 1; }
xcrun clang++ "${KEXT_LD[@]}" "$OUT/nvrm-fb.o" -o "$OUT/NVRMFB.kext/Contents/MacOS/NVRMFB" 2>"$OUT/nvrmfb-ld.err" || { head -15 "$OUT/nvrmfb-ld.err"; exit 2; }
cp "$SRC/fb/Info.plist" "$OUT/NVRMFB.kext/Contents/Info.plist"
file "$OUT/NVRMFB.kext/Contents/MacOS/NVRMFB"
