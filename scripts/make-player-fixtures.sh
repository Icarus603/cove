#!/bin/zsh
# Generates small real media files for testing the player (needs ffmpeg): tagged audio with cover art in several formats,
# a video, a video with two audio tracks and a subtitle track, a format the system cannot play, a broken file, a nested folder.
#
#   scripts/make-player-fixtures.sh /some/empty/dir
set -euo pipefail
OUT="${1:?usage: make-player-fixtures.sh <dir>}"
mkdir -p "$OUT/nested"
cd "$OUT"
ff() { ffmpeg -loglevel error -y "$@"; }
ff -f lavfi -i "color=c=0x2b6cb0:s=500x500:d=1" -frames:v 1 cover.png
ff -f lavfi -i "sine=frequency=440:duration=6" -i cover.png -map 0 -map 1 -c:a libmp3lame -c:v mjpeg -id3v2_version 3 \
   -metadata title="Alpha" -metadata artist="Test Artist" -metadata album="Test Album" -disposition:v attached_pic song_a.mp3
ff -f lavfi -i "sine=frequency=523:duration=5" -metadata title="Beta" -metadata artist="Test Artist" -metadata album="Second Album" song_b.flac
ff -f lavfi -i "sine=frequency=587:duration=4" -c:a aac -metadata title="Gamma" -metadata artist="Other Artist" song_c.m4a
ff -f lavfi -i "sine=frequency=659:duration=3" song_d.wav
ff -f lavfi -i "sine=frequency=330:duration=3" -c:a libmp3lame nested/song_e.mp3
ff -f lavfi -i "testsrc=size=640x360:rate=24:duration=12" -f lavfi -i "sine=frequency=330:duration=12" -c:v libx264 -pix_fmt yuv420p -c:a aac \
   -metadata title="Test Clip" -shortest clip.mp4
printf '1\n00:00:01,000 --> 00:00:04,000\nHello subtitle\n\n2\n00:00:05,000 --> 00:00:08,000\nSecond line\n' > subs.srt
ff -f lavfi -i "testsrc2=size=640x360:rate=24:duration=10" -f lavfi -i "sine=frequency=261:duration=10" -f lavfi -i "sine=frequency=392:duration=10" -i subs.srt \
   -map 0:v -map 1:a -map 2:a -map 3:s -c:v libx264 -pix_fmt yuv420p -c:a aac -c:s mov_text \
   -metadata:s:a:0 language=eng -metadata:s:a:0 title="English" -metadata:s:a:1 language=jpn -metadata:s:a:1 title="Japanese" \
   -metadata:s:s:0 language=eng -metadata title="Multi Track" multi.mp4
ff -f lavfi -i "testsrc=size=320x180:rate=24:duration=2" -c:v libx264 movie.mkv
echo "this is not audio" > broken.mp3
echo "just notes" > notes.txt
rm -f subs.srt
ls -la "$OUT" "$OUT/nested"
