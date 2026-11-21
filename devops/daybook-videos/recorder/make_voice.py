"""Render the voice-over for a scene file, one clip per scene.

usage: python3 -I make_voice.py ../scenes/V10.json [--text-only]

Writes ../voice/<id>/NN.txt (the narration) and NN.aiff (the audio), NN = scene number
from 01. edit.py picks these up and places each clip at its scene's start.

The default voice is a PLACEHOLDER: macOS `say -v Daniel` (British English). For a
published video, swap in a better TTS by setting TTS_CMD to a command template with
{txt} (input text file) and {out} (output audio file, any ffmpeg-readable format), e.g.
  TTS_CMD='my-tts --voice en-GB-1 --in {txt} --out {out}' TTS_EXT=wav python3 -I make_voice.py ...
After rendering, each clip is checked against its scene's duration: a clip longer than
its scene overlaps the next one, so shorten the text or lengthen the scene.
"""
import json
import os
import shlex
import subprocess
import sys

if len(sys.argv) < 2:
    sys.exit(__doc__)
scene = json.load(open(sys.argv[1]))
text_only = "--text-only" in sys.argv
here = os.path.dirname(os.path.abspath(__file__))
out_dir = os.path.join(here, "..", "voice", scene["id"])
os.makedirs(out_dir, exist_ok=True)
tts = os.environ.get("TTS_CMD", "say -v Daniel -r 175 -o {out} -f {txt}")
ext = os.environ.get("TTS_EXT", "aiff")

problems = 0
for n, sc in enumerate(scene["scenes"], start=1):
    txt = os.path.join(out_dir, f"{n:02d}.txt")
    with open(txt, "w") as f:
        f.write(sc["voice"].strip() + "\n")
    if text_only or not sc["voice"].strip():
        continue
    out = os.path.join(out_dir, f"{n:02d}.{ext}")
    cmd = [part.format(txt=txt, out=out) for part in shlex.split(tts)]
    subprocess.run(cmd, check=True)
    length = float(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", out],
        capture_output=True, text=True, check=True).stdout.strip())
    flag = ""
    if length > sc["duration"]:
        flag = f"  ✗ longer than the scene ({sc['duration']}s)"
        problems += 1
    print(f"{scene['id']} {sc['id']:>4} {length:5.1f}s / {sc['duration']:>3}s{flag}")

print(f"wrote {out_dir}" + (f" — {problems} clip(s) too long" if problems else ""))
sys.exit(1 if problems else 0)
