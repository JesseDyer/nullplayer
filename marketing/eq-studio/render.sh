#!/bin/bash
# render.sh [assets_dir]: builds <assets_dir>/out2/eq-studio-demo.mp4 from its clip_*.mp4 and out/bg.png (default ~/Documents/shots/promo-kit/eq-studio) — text-led cut — captions left, Studio window right; opener is text over clip_rain.mp4 (made by ../rain/skinrain.py)
set -e; ICON="$(cd "$(dirname "$0")/../.." && pwd)/Sources/NullPlayer/Resources/AppIcon.png"
cd "${1:-$HOME/Documents/shots/promo-kit/eq-studio}"; mkdir -p out2
OR='#ff9a2e'
side() { # name "title" "sub" : text block left-aligned at x=120, vertically centred
  magick -background none -fill white -font Avenir-Next-Heavy -pointsize ${TS:-74} -size 760x caption:"$2" \
    \( -size 760x30 xc:none \) \( -background none -fill "$OR" -font Avenir-Next-Demi-Bold -pointsize 38 -size 760x caption:"$3" \) \
    -append /tmp/np_blk.png
  [ -n "$4" ] && magick \( "$4" -trim +repage -resize 180x180 -gravity west -background none -extent 760x180 \) \( -size 760x36 xc:none \) /tmp/np_blk.png -append /tmp/np_blk.png
  magick -size 1920x1080 xc:none /tmp/np_blk.png -gravity west -geometry +120+0 -composite "out2/cap_$1.png"; }
full() { # name "title" "sub" : centred
  magick -background none -fill white -font Avenir-Next-Heavy -pointsize 80 -gravity center -size 1760x caption:"$2" \
    \( -size 1760x36 xc:none \) \( -background none -fill "$OR" -font Avenir-Next-Demi-Bold -pointsize 46 -gravity center -size 1760x caption:"$3" \) \
    -append /tmp/np_blk.png
  if [ -n "$4" ]; then   # brand row: logo + wordmark, centred above the text
    magick \( "$4" -trim +repage -resize 112x112 \) \( -size 26x112 xc:none \) \( +size -background none -fill white -font Avenir-Next-Heavy -pointsize 84 label:"NullPlayer" \) -background none -gravity center +append /tmp/np_brand.png
    magick -background none -gravity center /tmp/np_brand.png \( -size 10x54 xc:none \) /tmp/np_blk.png -append /tmp/np_blk.png
  fi
  magick -size 1920x1080 xc:none /tmp/np_blk.png -gravity center -composite "out2/cap_$1.png"; }
top() { # name "title" "sub" : centred block at the top
  magick -background none -fill white -font Avenir-Next-Heavy -pointsize 64 -gravity center -size 1760x caption:"$2" \
    \( -size 1760x18 xc:none \) \( -background none -fill "$OR" -font Avenir-Next-Demi-Bold -pointsize 38 -gravity center -size 1760x caption:"$3" \) \
    -append /tmp/np_blk.png
  magick -size 1920x1080 xc:none /tmp/np_blk.png -gravity north -geometry +0+44 -composite "out2/cap_$1.png"; }
full 1 "Every album is mastered differently.\nEvery ear hears differently." "One EQ setting can't fit them all." "$ICON"
top 2 "Give every track, album or artist its own EQ profile" "Right-click  ›  Assign EQ Profile  ›  pick a profile"
side 3 "Every time you play it, your EQ is applied." "Set it once. Forget it forever."
side 4 "Pro-grade tools." "31-band graphic  ·  4-band parametric  ·  tune each ear on its own"
TS=60 side 5 "NullPlayer\nEqualizer Studio\nand Equalizer Profiles" "Pro-grade 31-band graphic EQ\n4-band parametric\nTune each ear on its own\nTune your library with NullPlayer" "$ICON"
: > out2/list.txt
seg() { # name clip start dur caption fade layout(side|full)
  local f="" v; [ "$6" = 1 ] && f=",fade=in:st=0:d=0.3:alpha=1"
  if [ "$7" = top ]; then
    v="[0:v]fps=60,scale=w=1600:h=800:force_original_aspect_ratio=decrease:flags=lanczos,setsar=1[w];[1:v][w]overlay=(W-w)/2:236[b]"
  elif [ "$7" = rain ]; then
    v="[0:v]fps=60,setsar=1[b]"
  elif [ "$7" = full ]; then
    v="[0:v]fps=60,scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,boxblur=24:2,eq=brightness=-0.12:saturation=0.9,setsar=1[b]"
  else
    v="[0:v]fps=60,scale=w=880:h=720:force_original_aspect_ratio=decrease:flags=lanczos,setsar=1[w];[1:v][w]overlay=1920-120-w:(H-h)/2[b]"
  fi
  ffmpeg -v error -y -ss "$3" -t "$4" -i "clip_$2.mp4" -loop 1 -t "$4" -i out/bg.png -loop 1 -t "$4" -i "out2/cap_$5.png" \
    -filter_complex "$v;[2:v]format=rgba$f[c];[b][c]overlay=0:0,format=yuv420p[o]" \
    -map "[o]" -t "$4" -r 60 -c:v libx264 -crf 16 -preset slow -an "out2/$1.mp4"
  echo "file '$1.mp4'" >> out2/list.txt; }
seg s1  rain       0.0 3.5 1 1 rain
seg s2  assigncrop 1.8 4.5 2 1 top
seg s3a halo       0.3 2.25 3 1 side
seg s3b halo_c     0.3 2.25 3 0 side
seg s5a hifi       1.9 1.25 5 1 side
seg s5b cparam     2.0 1.25 5 0 side
ffmpeg -v error -y -f concat -safe 0 -i out2/list.txt -c copy out2/eq-studio-demo.mp4
