# NullMoth 驱动自建环境（source 本文件使用）
export OGKM=${OGKM:-$HOME/ogkm610}
export NMSRC=${NMSRC:-/Users/velo/nvdrv-src}
export SDK="$(xcrun --show-sdk-path)"
export KHDR="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
export NV="$OGKM/src/nvidia"
export KMS="$OGKM/src/nvidia-modeset"

export RMINC=( -I"$NV/arch/nvalloc/unix/include" -I"$NV/arch/nvalloc/common/inc" -I"$NV/arch/nvalloc/common/inc/gsp"
  -I"$OGKM/src/common/sdk/nvidia/inc" -I"$OGKM/src/common/sdk/nvidia/inc/hw" -I"$OGKM/src/common/inc"
  -I"$OGKM/src/common/shared/inc" -I"$NV/inc" -I"$NV/inc/os" -I"$NV/inc/kernel" -I"$NV/kernel/inc" -I"$NV/interface"
  -I"$OGKM/src/common/nvlink/interface" -I"$OGKM/src/common/inc/swref" -I"$OGKM/src/common/inc/swref/published"
  -I"$NV/inc/libraries" -I"$NV/src/libraries" -I"$NV/generated" -I"$NV/src/mm/uvm/interface"
  -I"$OGKM/src/common/uproc/os/libos-v2.0.0/include" -I"$OGKM/src/common/uproc/os/common/include"
  -I"$OGKM/src/common/inc/displayport" -I"$OGKM/src/common/nvlink/inband/interface" )

export KMSINC=( -I"$KMS/os-interface/include" -I"$KMS/kapi/interface" -I"$KMS/kapi/include"
  -I"$OGKM/src/common/unix/nvidia-push/interface" -I"$KMS/interface" -I"$KMS/include"
  -I"$OGKM/src/common/unix/common/inc" -I"$OGKM/src/common/modeset" -I"$OGKM/src/common/unix/common/utils/interface" )

# RM 的 -D 集合：取自 gen_compile_cmds.sh 生成的 compile_cmds.sh（与作者脚本同一做法）
RMDEFS=(); while read -r d; do RMDEFS+=("$d"); done < <(head -1 "$NV/_out/Darwin_x86_64/compile_cmds.sh" | tr ' ' '\n' \
  | grep -E '^-D' | sed -e 's/"//g' | grep -v -E '^-D(NVRM|_LANGUAGE_C)$')
export RMDEFS

# kext 源码的编译参数。平台宏 -DNV_BSD -DNV_UNIX 必须显式给：
# cpuopsys.h 只在 __FreeBSD__ 时定义 NV_BSD，macOS 上 clang 不会给，而 nvUnixVersion.h / nvport 都要求它。
export KEXT_CXX=( -arch x86_64 -fapple-kext -mkernel -nostdinc -I"$KHDR"
  -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -DNV_BSD -DNV_UNIX
  "${RMDEFS[@]}" -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common
  -Wall -Wno-unused-parameter -Wno-inconsistent-missing-override -Wno-unused-function -O2 )

export KEXT_CFLAGS=( -arch x86_64 -fapple-kext -mkernel -nostdinc -I"$KHDR"
  -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -DNV_BSD -DNV_UNIX
  "${RMDEFS[@]}" -std=gnu11 -fno-builtin -fno-common
  -Wall -Wno-unused-parameter -Wno-unused-function -O2 )

export KEXT_LD=( -arch x86_64 -fapple-kext -nostdlib -Xlinker -kext -lkmodc++ -lkmod -lcc_kext )
