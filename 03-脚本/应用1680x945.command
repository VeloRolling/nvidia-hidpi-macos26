#!/bin/bash
# 应用「1680x945 清晰档」：重建一次性开机任务，重启后生效
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
TPL="$DIR/开机任务-wsconfig.plist"
SRC="/Library/Application Support/HiDPI/windowserver-1680x945.plist"

if [ ! -f "$SRC" ]; then
  echo "缺少配置：$SRC"
  read -r -p "按回车退出..." _; exit 1
fi
if [ ! -f "$TPL" ]; then
  echo "缺少模板：$TPL"
  read -r -p "按回车退出..." _; exit 1
fi

CMD="/bin/cp $(printf '%q' "$TPL") /Library/LaunchDaemons/local.hidpi.wsconfig.plist && /usr/sbin/chown root:wheel /Library/LaunchDaemons/local.hidpi.wsconfig.plist && /bin/chmod 644 /Library/LaunchDaemons/local.hidpi.wsconfig.plist && /usr/bin/plutil -lint /Library/LaunchDaemons/local.hidpi.wsconfig.plist"
osascript -e "do shell script \"$CMD\" with administrator privileges"

echo
echo "已装好一次性开机任务：重启后会应用 1680x945（缓冲 3360x1890，2 倍）"
echo "重启后到「系统设置 → 显示器」确认显示为 1680 x 945"
echo
read -r -p "现在重启吗？(y/N) " a
if [ "$a" = "y" ]; then
  osascript -e 'tell application "System Events" to restart'
fi
