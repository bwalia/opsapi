"""Edit a recording made by run.mjs into a finished video with captions.

usage: python3 -I edit.py <rec dir> [--end SECONDS] [--voice DIR] [--no-voice]

<rec dir> is out/<id>/ holding raw.webm, segments.json, captions.json, timeline.json.
Writes <rec dir>/<id>.mp4 and <id>.vtt.

- A "cut" segment is dropped.
- Any other segment longer than LONG seconds is sped up to TARGET seconds
  (statement processing to 25 s, everything else to 4 s).
- Captions are re-timed onto the edited video.
- If ../voice/<id>/NN.(wav|aiff|m4a) exist (from make_voice.py, NN = scene number from 01),
  each clip starts at its scene's edited start time and is mixed into one audio track.
Generalised from devops/demo/landlord-video/edit.py.
"""
import glob
import json
import os
import subprocess
import sys

LONG = 8.0
TARGETS = {"processing": 25.0, "sorting": 20.0}
DEFAULT_TARGET = 4.0

args = sys.argv[1:]
if not args:
    sys.exit(__doc__)
rec = args[0].rstrip("/")
end_at = float(args[args.index("--end") + 1]) if "--end" in args else None
here = os.path.dirname(os.path.abspath(__file__))

raw = f"{rec}/raw.webm"
segs = sorted(json.load(open(f"{rec}/segments.json")), key=lambda s: s["start"])
caps = json.load(open(f"{rec}/captions.json")) if os.path.exists(f"{rec}/captions.json") else []
timeline = json.load(open(f"{rec}/timeline.json")) if os.path.exists(f"{rec}/timeline.json") else []
vid = json.load(open(f"{rec}/scene.json"))["id"] if os.path.exists(f"{rec}/scene.json") else os.path.basename(rec)
voice_dir = args[args.index("--voice") + 1] if "--voice" in args else os.path.join(here, "..", "voice", vid)

dur = float(subprocess.run(
    ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", raw],
    capture_output=True, text=True, check=True).stdout.strip())
if end_at:
    dur = min(dur, end_at)

# (start, end, speed) pieces covering the kept video; speed 0 = dropped.
pieces, cur = [], 0.0
for s in segs:
    a, b = max(s["start"], cur), min(s["end"], dur)
    if b <= a:
        continue
    if s["label"] == "cut":
        if a > cur:
            pieces.append((cur, a, 1.0))
        pieces.append((a, b, 0.0))
        cur = b
        continue
    if b - a <= LONG:
        continue
    if a > cur:
        pieces.append((cur, a, 1.0))
    pieces.append((a, b, (b - a) / TARGETS.get(s["label"], DEFAULT_TARGET)))
    cur = b
if cur < dur:
    pieces.append((cur, dur, 1.0))


def edited(t, clamp=False):
    """Map a raw time to the edited timeline. A time inside a cut is None, or with
    clamp=True the point where the cut was made."""
    out = 0.0
    for a, b, sp in pieces:
        if t < a:
            break
        if sp == 0.0:
            if t < b:
                return out if clamp else None
            continue
        if t < b:
            return out + (t - a) / sp
        out += (b - a) / sp
    return out


kept = [p for p in pieces if p[2] > 0]
parts = [f"[0:v]trim=start={a:.3f}:end={b:.3f},setpts=(PTS-STARTPTS)/{sp:.4f}[v{i}]"
         for i, (a, b, sp) in enumerate(kept)]
filt = ";".join(parts) + ";" + "".join(f"[v{i}]" for i in range(len(kept))) \
    + f"concat=n={len(kept)}:v=1:a=0,fps=25[vout]"
total = sum((b - a) / sp for a, b, sp in kept)

# Voice-over: one clip per scene, delayed to the scene's edited start.
inputs, amix = ["-i", raw], ""
clips = []
if "--no-voice" not in args and os.path.isdir(voice_dir):
    for n, sc in enumerate(timeline, start=1):
        found = sorted(glob.glob(os.path.join(voice_dir, f"{n:02d}.*")))
        found = [f for f in found if not f.endswith(".txt")]
        start = edited(sc["start"])
        if found and start is not None:
            clips.append((found[0], start))
if clips:
    for f, _ in clips:
        inputs += ["-i", f]
    delays = [f"[{i + 1}:a]adelay={int(st * 1000)}|{int(st * 1000)}[a{i}]" for i, (_, st) in enumerate(clips)]
    amix = ";" + ";".join(delays) + ";" + "".join(f"[a{i}]" for i in range(len(clips))) \
        + f"amix=inputs={len(clips)}:normalize=0,apad,atrim=0:{total:.3f}[aout]"

out = f"{rec}/{vid}.mp4"
cmd = ["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", filt + amix, "-map", "[vout]"]
if clips:
    cmd += ["-map", "[aout]", "-c:a", "aac", "-b:a", "160k"]
cmd += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "21", "-preset", "medium", "-movflags", "+faststart", out]
subprocess.run(cmd, check=True)


def ts(t):
    h, r = divmod(max(t, 0.0), 3600)
    m, s = divmod(r, 60)
    return f"{int(h):02d}:{int(m):02d}:{s:06.3f}"


# Captions: each caption runs until the next one (or the end); empty ones end a cue.
cues = []
for i, c in enumerate(caps):
    if not c["text"]:
        continue
    a = edited(c["t"])
    nxt = caps[i + 1]["t"] if i + 1 < len(caps) else dur
    b = edited(min(nxt, dur), clamp=True)
    if a is None or b is None or b - a < 0.4:
        continue
    cues.append((a, b, c["text"]))
with open(f"{rec}/{vid}.vtt", "w") as f:
    f.write("WEBVTT\n\n")
    for n, (a, b, text) in enumerate(cues, start=1):
        f.write(f"{n}\n{ts(a)} --> {ts(b)}\n{text}\n\n")

# Chapters for the YouTube description, from scene starts.
chapters = []
for sc in timeline:
    st = edited(sc["start"])
    if st is not None:
        m, s = divmod(int(st), 60)
        chapters.append(f"{m}:{s:02d} {sc['caption'][:60]}")
open(f"{rec}/{vid}.chapters.txt", "w").write("\n".join(chapters) + "\n")

print(f"raw {dur:.0f}s -> edited {total:.0f}s, {sum(1 for p in pieces if p[2] > 1)} wait(s) sped up, "
      f"{sum(1 for p in pieces if p[2] == 0)} cut(s), {len(cues)} captions, {len(clips)} voice clips -> {out}")
