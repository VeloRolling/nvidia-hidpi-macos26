#!/bin/bash
# 回滚 NVRM.kext 到 NullMoth 官方 2.4.3（撤销 planE 实验）
# 双击运行，会要求输入管理员密码；完成后可选择重启
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BK="$DIR/backup-原始NVRM-2.4.3"
DEST=/Library/Extensions/NVRM.kext
AUX=/Library/KernelCollections/AuxiliaryKernelExtensions.kc

clear
echo "=================================================="
echo " 回滚 NVRM.kext 到官方 2.4.3"
echo " 来源: $BK"
echo "=================================================="
echo

if [ ! -d "$BK/NVRM.kext.orig" ]; then
  echo "✗ 备份不完整，已中止（未做任何改动）"
  echo "  需要: $BK/NVRM.kext.orig"
  read -r -p "按回车关闭..." _; exit 1
fi
if [ ! -f "$BK/AuxiliaryKernelExtensions.kc.orig" ]; then
  echo "注: 本包为精简版，未附带 AuxKC 备份，将直接用 kmutil 从 /Library/Extensions 重建内核集合。"
  echo
fi

echo "即将执行："
echo "  1) 用备份替换 $DEST"
echo "  2) 用备份恢复 $AUX"
echo "  3) 重建内核集合并校验"
echo
read -r -p "继续？(y/N) " ok
[ "$ok" = "y" ] || [ "$ok" = "Y" ] || { echo "已取消"; exit 0; }

sudo /bin/bash -s "$BK" "$DEST" "$AUX" <<'EOS'
set -uo pipefail
BK="$1"; DEST="$2"; AUX="$3"
echo "== 恢复 kext =="
rm -rf "$DEST"
ditto "$BK/NVRM.kext.orig" "$DEST" || exit 1
chown -R root:wheel "$DEST"
chmod -R go-w "$DEST"
echo "== 恢复内核集合 =="
if [ -f "$BK/AuxiliaryKernelExtensions.kc.orig" ]; then
  cp -p "$BK/AuxiliaryKernelExtensions.kc.orig" "$AUX" || exit 1
  echo "已用备份覆盖：$AUX"
else
  echo "无 AuxKC 备份，跳过覆盖（下一步会重建）"
fi
echo "== 重建集合并校验 =="
kmutil create -n aux --volume-root / --allow-missing-kdk \
  --kernel /System/Library/Kernels/kernel \
  -B /System/Library/KernelCollections/BootKernelExtensions.kc \
  -S /System/Library/KernelCollections/SystemKernelExtensions.kc \
  --repository /Library/Extensions -A "$AUX" -z || echo "(重建返回非 0，集合仍为备份的旧集合)"
echo "== 集合内容 =="
kmutil inspect -a x86_64 -A "$AUX" 2>&1 | grep -i nullmoth
EOS

echo
echo "回滚完成。建议重启一次。"
read -r -p "现在重启？(y/N) " rb
[ "$rb" = "y" ] || [ "$rb" = "Y" ] && sudo shutdown -r now
