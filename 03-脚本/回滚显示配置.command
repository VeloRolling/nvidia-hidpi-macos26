#!/bin/bash
# 回滚显示配置：恢复成原来的 1280x720 清晰档（重启后生效）
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
TPL="$DIR/开机任务-回滚.plist"
BAK="/Library/Application Support/HiDPI/windowserver-before.bak.plist"

if [ ! -f "$BAK" ]; then
  echo "缺少备份：$BAK"
  read -r -p "按回车退出..." _; exit 1
fi
if [ ! -f "$TPL" ]; then
  echo "缺少模板：$TPL"
  read -r -p "按回车退出..." _; exit 1
fi

CMD="/bin/cp $(printf '%q' "$TPL") /Library/LaunchDaemons/local.hidpi.wsconfig.plist; /usr/sbin/chown root:wheel /Library/LaunchDaemons/local.hidpi.wsconfig.plist; /bin/chmod 644 /Library/LaunchDaemons/local.hidpi.wsconfig.plist; /usr/bin/plutil -lint /Library/LaunchDaemons/local.hidpi.wsconfig.plist"
osascript -e "do shell script \"$CMD\" with administrator privileges"

echo
echo "已装好回滚任务：重启后会恢复成原来的 1280x720 清晰档。"
echo
read -r -p "现在重启吗？(y/N) " a
if [ "$a" = "y" ]; then
  osascript -e 'tell application "System Events" to restart'
fi
