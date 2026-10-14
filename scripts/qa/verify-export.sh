#!/bin/sh
# usage: verify-export.sh file.mp4 expected_w expected_h expected_duration_s [tol_s]
f=$1; w=$2; h=$3; d=$4; tol=${5:-0.05}
got=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$f") || exit 1
[ "$got" = "$w,$h" ] || { echo "size $got != $w,$h"; exit 1; }
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")
awk -v a="$dur" -v b="$d" -v t="$tol" 'BEGIN{x=a-b; if(x<0)x=-x; exit !(x<=t)}' || { echo "duration $dur != $d"; exit 1; }
ffmpeg -v error -i "$f" -f null - || { echo "decode errors"; exit 1; }
echo "export ok: $w x $h, ${dur}s"
