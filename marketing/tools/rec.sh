#!/bin/zsh
# rec.sh <label> <secs>  (writes $OUT/clip_<label>.mp4, OUT defaults to the current dir; PID defaults to the running NullPlayer)
# rec.sh <label> <secs> [winhelper gesture args...] : record the EQ Studio window region, optionally driving a gesture
cd "${0:A:h}/../.."
PID=${PID:-$(pgrep -x NullPlayer | head -1)}; WH=skills/app-control/scripts/winhelper; S=${OUT:-$OLDPWD}; L=$1; T=$2; shift 2
read -r WID _ X Y W H _ < <($WH windows --pid $PID | awk -F'\t' '$8=="EQ Studio"')
[ -n "$X" ] || { echo "NO-STUDIO"; exit 1; }
$WH raise $PID >/dev/null || exit 1
ffmpeg -v error -y -f avfoundation -framerate 60 -capture_cursor 0 -i "2:none" -t $T -vf "crop=$((W*2)):$((H*2)):$((X*2)):$((Y*2))" -c:v libx264 -preset ultrafast -crf 12 -pix_fmt yuv420p $S/clip_$L.mp4 &>/dev/null & CP=$!
if (( $# )); then sleep 1.5; $WH "$@" >/dev/null; fi
wait $CP; echo "rec $L ${W}x${H}"
