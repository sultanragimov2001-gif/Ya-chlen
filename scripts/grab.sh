#!/usr/bin/env bash
# Downloads each video from videos.txt and extracts visual reference material into out/<id>/:
# thumbnail, trimmed metadata, subtitles, scene-change frames, contact sheets, motion strips, cut stats.
set -u
mkdir -p out

while read -r id; do
  [ -z "$id" ] && continue
  d="out/$id"
  mkdir -p "$d/frames" "$d/motion"
  url="https://www.youtube.com/watch?v=$id"

  curl -sfL -o "$d/thumb.jpg" "https://i.ytimg.com/vi/$id/maxresdefault.jpg" \
    || curl -sfL -o "$d/thumb.jpg" "https://i.ytimg.com/vi/$id/hqdefault.jpg"

  opts=(-f "bv*[height<=720]+ba/b[height<=720]/b" --merge-output-format mp4
        --write-info-json --write-auto-subs --write-subs --sub-langs "ru,ru-orig,en" --sub-format vtt
        -o "$d/video.%(ext)s")
  yt-dlp "${opts[@]}" "$url" > "$d/ytdlp.log" 2>&1 \
    || yt-dlp "${opts[@]}" --extractor-args "youtube:player_client=tv,mweb,web_safari" "$url" >> "$d/ytdlp.log" 2>&1

  if [ -f "$d/video.info.json" ]; then
    jq '{title, channel, channel_url, duration, upload_date, view_count, like_count, width, height, fps,
         description, tags, categories, chapters}' "$d/video.info.json" > "$d/meta.json"
    rm -f "$d/video.info.json"
  fi

  v=$(ls "$d"/video.mp4 "$d"/video.webm "$d"/video.mkv 2>/dev/null | head -1)
  if [ -z "$v" ]; then
    echo "no video for $id" >> "$d/ytdlp.log"
    continue
  fi

  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$v")

  # Scene cuts: timestamps + up to 60 frames at the cuts
  ffmpeg -nostdin -loglevel error -i "$v" -an \
    -vf "select='gt(scene,0.3)',metadata=print:file=$d/scenes.txt" -f null -
  ffmpeg -nostdin -loglevel error -i "$v" -an \
    -vf "select='gt(scene,0.3)',scale=640:-2" -fps_mode vfr -frames:v 60 -q:v 4 "$d/frames/scene_%03d.jpg"

  # Overview: 24 evenly spaced frames, and the first 10 s (hook) at 2 fps
  ffmpeg -nostdin -loglevel error -i "$v" -an \
    -vf "fps=24/$dur,scale=480:-2,tile=6x4" -frames:v 1 -q:v 4 "$d/contact.jpg"
  ffmpeg -nostdin -loglevel error -t 10 -i "$v" -an \
    -vf "fps=2,scale=480:-2,tile=5x4" -frames:v 1 -q:v 4 "$d/hook.jpg"

  # Motion strips: 4 frames 0.4 s apart at 20/40/60/80 % of the video (zoom/pan vs AI-video motion)
  for p in 20 40 60 80; do
    t=$(python3 -c "print($dur*$p/100)")
    ffmpeg -nostdin -loglevel error -ss "$t" -t 1.6 -i "$v" -an \
      -vf "fps=2.5,scale=480:-2,tile=4x1" -frames:v 1 -q:v 4 "$d/motion/strip_$p.jpg"
  done

  python3 - "$d/scenes.txt" "$dur" > "$d/stats.json" <<'PY'
import json, re, statistics, sys
path, dur = sys.argv[1], float(sys.argv[2])
cuts = [float(m) for m in re.findall(r"pts_time:([\d.]+)", open(path).read())]
bounds = [0.0] + cuts + [dur]
shots = [b - a for a, b in zip(bounds, bounds[1:]) if b - a > 0.05]
print(json.dumps({
    "duration_s": round(dur, 1),
    "cuts": len(cuts),
    "avg_shot_s": round(statistics.mean(shots), 2) if shots else None,
    "median_shot_s": round(statistics.median(shots), 2) if shots else None,
    "shortest_s": round(min(shots), 2) if shots else None,
    "longest_s": round(max(shots), 2) if shots else None,
    "cut_times_s": [round(c, 2) for c in cuts],
}, indent=2))
PY

  rm -f "$v"
done < videos.txt
