#!/bin/zsh
# snap.sh <submenu> <item> <label> : switch skin in the running app, capture the EQ Studio window
cd "${0:A:h}/../.."
PID=${PID:-$(pgrep -x NullPlayer | head -1)}; WH=skills/app-control/scripts/winhelper; S=${OUT:-$OLDPWD}
osascript skills/app-control/scripts/menu.applescript skin $PID "$1" "$2" >/dev/null || { echo "MENU-FAIL $3"; exit 1; }
sleep ${SETTLE:-4}
WID=$($WH windows --pid $PID | awk -F'\t' '$8=="EQ Studio"{print $1; exit}')
[ -n "$WID" ] || { echo "NO-STUDIO $3"; exit 1; }
$WH capture $WID $S/still_$3.png --pid $PID | cut -f2-
