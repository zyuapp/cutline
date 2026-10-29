#!/bin/sh
# Generates sample media for development into Fixtures/generated (needs ffmpeg).
set -eu
out=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/Fixtures/generated
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT

say -v Samantha -o "$tmp/talk.aiff" "Hi, I'm testing Cutline, an editor that an agent drives. [[slnc 1400]] Um, so the idea is simple. [[slnc 900]] You talk to Claude, and uh, it edits the video for you. [[slnc 1600]] It can cut pauses, remove filler words, and add captions. [[slnc 700]] Uh, and you just watch the preview and leave comments. [[slnc 1200]] That's it. Thanks for watching."
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp/talk.aiff")
ffmpeg -v error -y -f lavfi -i "testsrc2=size=1920x1080:rate=30" -i "$tmp/talk.aiff" \
  -t "$dur" -c:v h264 -pix_fmt yuv420p -c:a aac -b:a 160k "$out/talking-head.mp4"

ffmpeg -v error -y -f lavfi -i "mandelbrot=size=1920x1080:rate=30" -t 8 -c:v h264 -pix_fmt yuv420p "$out/broll-fractal.mp4"
ffmpeg -v error -y -f lavfi -i "life=size=1080x1920:rate=30:mold=10:ratio=0.1:death_color=#1a1a2e:life_color=#e94560" -t 6 -c:v h264 -pix_fmt yuv420p "$out/vertical-life.mp4"
ffmpeg -v error -y -f lavfi -i "sine=frequency=220:duration=40" -f lavfi -i "sine=frequency=330:duration=40" -f lavfi -i "sine=frequency=440:duration=40" \
  -filter_complex "[0][1][2]amix=inputs=3,volume=0.6,tremolo=f=2:d=0.6,afade=t=in:d=2" -c:a aac "$out/music.m4a"
ffmpeg -v error -y -f lavfi -i "color=c=#FF5A36:size=512x512" -frames:v 1 "$out/logo.png"
ls -la "$out"
