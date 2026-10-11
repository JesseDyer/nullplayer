#!/bin/bash
# shoot.sh <pid> <picks.txt> <outdir> — per face: select via menu, wait for the load log line,
# then 8 window captures 0.25 s apart (frames/<n>/fNN.png) and a still (<n>.png).
set -u
PID=$1; PICKS=$2; OUT=$3; LOG=/tmp/np.log
SC="$(cd "$(dirname "$0")/../.." && pwd)/skills/app-control/scripts"
mkdir -p "$OUT/frames"
n=0
while IFS= read -r face; do
  n=$((n+1)); slug=$(printf '%02d_%s' $n "$(echo "$face" | sed 's/^ *//;s/ *$//;s/[^A-Za-z0-9]\{1,\}/_/g;s/^_//;s/_$//')")
  before=$(grep -cF "AudionFace: loaded '$face'" "$LOG")
  osascript "$SC/menu.applescript" skin "$PID" "Audion Faces" "$face" >/dev/null 2>&1 || { echo "MENU-FAIL $face"; continue; }
  ok=""; for i in $(seq 1 100); do sleep 0.1; [ "$(grep -cF "AudionFace: loaded '$face'" "$LOG")" -gt "$before" ] && { ok=1; break; }; done
  [ -z "$ok" ] && { echo "NO-LOAD $face"; continue; }
  sleep 0.3
  id=$("$SC/winhelper" windows --pid "$PID" | awk -F'\t' '$8 ~ /Audion/ {print $1; exit}')
  mkdir -p "$OUT/frames/$slug"
  for f in 1 2 3 4 5 6 7 8; do
    screencapture -o -x -l "$id" "$OUT/frames/$slug/f$f.png"; sleep 0.25
  done
  cp "$OUT/frames/$slug/f4.png" "$OUT/$slug.png"
  echo "OK $slug $(sips -g pixelWidth -g pixelHeight "$OUT/$slug.png" | awk '/pixel/{printf "%s ", $2}')"
done < "$PICKS"
