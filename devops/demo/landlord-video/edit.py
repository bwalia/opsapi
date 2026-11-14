"""Compress the long waits in out/raw.webm and write out/landlord-file-with-ai.mp4.

Each recorded wait longer than LONG seconds is played back so it lasts TARGET
seconds; everything else plays at normal speed.
usage: python3 -I edit.py <rec dir> [out subdir] [end seconds]
A "cut" segment is dropped; an end time stops the video there (raw seconds).
"""
import json
import subprocess
import sys

LONG = 8.0
TARGETS = {"processing": 25.0}
DEFAULT_TARGET = 4.0
rec = sys.argv[1]
sub = sys.argv[2] if len(sys.argv) > 2 else "out"
end_at = float(sys.argv[3]) if len(sys.argv) > 3 else None
raw = f"{rec}/{sub}/raw.webm"
segs = sorted(json.load(open(f"{rec}/{sub}/segments.json")), key=lambda s: s["start"])
dur = float(subprocess.run(
    ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", raw],
    capture_output=True, text=True, check=True).stdout.strip())
if end_at:
    dur = min(dur, end_at)

# Build (start, end, speed) pieces covering the whole video.
pieces, cur = [], 0.0
for s in segs:
    a, b = max(s["start"], cur), min(s["end"], dur)
    if s["label"] == "cut":
        if a > cur:
            pieces.append((cur, a, 1.0))
        cur = max(cur, b)
        continue
    if b - a <= LONG:
        continue
    if a > cur:
        pieces.append((cur, a, 1.0))
    pieces.append((a, b, (b - a) / TARGETS.get(s["label"], DEFAULT_TARGET)))
    cur = b
if cur < dur:
    pieces.append((cur, dur, 1.0))

parts = []
for i, (a, b, speed) in enumerate(pieces):
    parts.append(f"[0:v]trim=start={a:.3f}:end={b:.3f},setpts=(PTS-STARTPTS)/{speed:.4f}[v{i}]")
filt = ";".join(parts) + ";" + "".join(f"[v{i}]" for i in range(len(pieces))) \
    + f"concat=n={len(pieces)}:v=1:a=0,fps=25[out]"
out = f"{rec}/{sub}/landlord-file-with-ai.mp4"
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", raw, "-filter_complex", filt, "-map", "[out]",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "23", "-preset", "medium",
                "-movflags", "+faststart", out], check=True)
new = sum((b - a) / sp for a, b, sp in pieces)
print(f"raw {dur:.0f}s -> edited {new:.0f}s, {sum(1 for p in pieces if p[2] > 1)} wait(s) compressed -> {out}")
