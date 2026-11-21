# Daybook videos: production kit

Everything needed to script, record, edit, caption, voice and publish the Daybook demo
videos (daybook.co.uk/videos):

- **Names and data:** `docs/plans/DAYBOOK_DEMO_SPEC.md`.
- **What we may claim:** §0 of `docs/plans/PROMPT_DAYBOOK_SITE.md`.

| Path | What |
|---|---|
| `catalogue.json` | **Source of truth** for every video: id, slug, title, audience, `vertical`, playlist, format, length, status, gate, demo workspace and clients, the code each one shows, YouTube title, description and tags, chapters, thumbnail text |
| `scripts/Vxx.md` | Scene-by-scene script for every unpublished video: on-screen action, caption, voice-over, duration |
| `scenes/Vxx.json` | Machine-readable scene file the recorder runs (priority videos so far: V08, V10, V11, V12, V28, V29) |
| `recorder/` | Playwright recorder (`lib.mjs`, `run.mjs`), editor (`edit.py`), voice-over (`make_voice.py`), thumbnails (`thumbnail.html`, `make_thumbnail.mjs`) |
| `voice/<id>/` | Narration text and rendered audio per scene (audio is git-ignored) |
| `thumbs/` | Rendered thumbnails (git-ignored); `thumbs/shots/<id>.png` = the screenshot set inside each one |

Generalised from `devops/demo/landlord-video/`, which made V01–V07.

## Statuses

| Status | Meaning |
|---|---|
| `published` | On YouTube (V01–V07, recorded on OpsAPI int; re-upload or re-record under Daybook per decision §1.4) |
| `planned` | Script ready. Film when the demo it needs exists (`dependsOn` names a vertical demo, if any) |
| `gated` | Film only after the `gate` condition is checked (e.g. confirm mobile apps, Peppol delivery, CIS) |
| `roadmap` | The feature isn't built. Script only, **never film**. Entries with `scriptOnly: true` include the Payroll and Corporation Tax series, which wait for those modules (`docs/plans/PROMPT_PAYROLL*.md`, `PROMPT_CORPORATION_TAX.md`) and must not claim live HMRC or Companies House filing |

Integration and feature videos are filmed only for what the code does today. Each entry's
`features[].paths` points at the code; if a path stops existing, re-check the claim.

## Recording a video end to end

### 1. Before you start

- **The demo is seeded:** `demo.daybook.co.uk`, workspace for the video's
  `demo.namespace` (e.g. `daybook-demo`), with the clients the script names.
- **A recording account with write access.**
  - The published login `demo@daybook.co.uk` is a read-only `viewer`. Every change is
    refused, and `run.mjs` refuses to use it.
  - Scripts that confirm lines, send questions or file need a staff or client account
    from the seed (e.g. Ade Okoro, Tom Reid) with a known password.
  - Set those passwords at recording time and keep them out of the repo.
  - Never give the published login write access to make a recording easier.
- **Recording changes shared demo data.** Record against a separate recording copy
  (same chart and seed, e.g. a `daybook-rec` release or a local stack), or re-run the
  demo seed and reset job straight after recording.
- **Any HMRC filing in a video goes to HMRC's sandbox**, with a test user from
  `sidecars/hmrc-test-users`. Blur NINOs and test-user IDs.

### 2. A private folder (`REC_SECRETS`), never in this repo

```
$REC_SECRETS/
  accounts.json            { "staff:ade": {"email": "...", "password": "..."},
                             "staff:ruth": {...}, "client:C3": {...}, "client:C6": {...} }
  statements/C6/*.pdf      synthetic statements for upload scenes
                           (devops/demo/landlord-video/make_statements.py makes them)
```

The keys are the `login` / `signIn.account` values in the scene files.

### 3. Record

```bash
cd devops/daybook-videos/recorder
npm install && npx playwright install chromium          # once
node run.mjs ../scenes/V10.json --dry                   # validate + print the timing plan
REC_SECRETS=/private/rec node run.mjs ../scenes/V10.json
#   BASE / API override the dashboard / API (default demo.daybook.co.uk / demo-api.daybook.co.uk)
#   --from s4 / --only s4 re-shoot from or just one scene
```

- **Output:** `out/V10/` with `raw.webm`, `segments.json`, `captions.json`,
  `timeline.json` and `scene.json`.
- **On failure:** `failure.png` shows the screen at the moment it broke.
- **Optional actions:** an action marked `"optional": true` is skipped (and logged) if
  its element isn't there. Check the log for skipped actions that matter.

### 4. Voice-over (placeholder voice)

```bash
python3 -I make_voice.py ../scenes/V10.json              # macOS `say -v Daniel`
TTS_CMD='my-tts --voice en-GB --in {txt} --out {out}' TTS_EXT=wav python3 -I make_voice.py ../scenes/V10.json
```

- **Flagging:** it flags any clip longer than its scene. Shorten the text or lengthen
  the scene.
- **Placeholder only:** `say` is fine for review cuts. Use a proper British voice for
  anything published.

### 5. Edit

```bash
python3 -I edit.py out/V10        # → out/V10/V10.mp4, V10.vtt, V10.chapters.txt
```

- **Speed-up:** waits over 8 s play in 4 s; `processing` waits in 25 s.
- **Cuts:** `cut` segments are dropped.
- **Captions** are re-timed to the edited video.
- **Voice:** each voice clip starts at its scene's edited start.

### 6. Thumbnail

```bash
ffmpeg -ss 00:00:40 -i out/V10/V10.mp4 -frames:v 1 ../thumbs/shots/V10.png
node make_thumbnail.mjs V10        # → ../thumbs/V10-<slug>.jpg (1280×720, Daybook navy/gold)
```

Thumbnail text comes from the entry's `thumbnail` block in `catalogue.json`.

### Writing a new scene file

Copy a file in `scenes/`. Each scene has `id`, `duration` (seconds; the recorder holds
the scene at least this long so the voice fits), `caption`, `voice`, an `action` note
for humans, and `actions[]`.

The actions:

- **Navigation:** `goto {path}`, `nav {menu, group}` (sidebar item), `reload`,
  `workspace {name}`.
- **Input:** `click`, `hover`, `fill`, `type`, `select`, `check`, `press`,
  `upload {dir, match, target}`.
- **Waiting and view:** `scroll`, `wait {ms}`, `waitFor`, `highlight` (gold box).
- **Captions and editing:** `caption {text}`, `slow {label, until:{gone|visible}}`
  (sped up in the edit), `cutStart` / `cutEnd` (dropped in the edit).
- **Sign-in:** `signIn {account}`, `viewport`.

Targets are `{role, name}`, `{text}`, `{label}`, `{placeholder}`, `{testid}` or `{css}`.
Values like `"/^Please check \\(\\d+\\)$/"` are regexes. Add `nth`, `last` or `within`
to narrow a target.

Keep `scripts/Vxx.md` in step with the scene file. The script is what reviewers read.

## Production checklist (each video)

- [ ] Script reviewed against §0 of the site prompt:
  - no "HMRC approved";
  - "a person signs off" wherever AI appears;
  - no invented numbers;
  - roadmap and gated items not shown as available.
- [ ] MTD explainer dates, thresholds and penalties re-checked on GOV.UK the week of
      recording. Sources are in the entry's `sources`.
- [ ] Demo seeded; recording account ready; nothing real on screen. NINOs and HMRC
      test IDs blurred.
- [ ] `run.mjs --dry` timing matches the target length.
- [ ] Recorded, edited, captions read through, voice rendered (final voice, not `say`).
- [ ] Watched once end to end at full size and once on a phone.
- [ ] Thumbnail rendered.
- [ ] Demo data reset after recording.

## Publishing checklist

- [ ] Upload to the Daybook YouTube channel:
  - title and description from `catalogue.json` → `youtube`;
  - the description opens with what the viewer will see and links to
    `https://daybook.co.uk/videos/<slug>/`;
  - chapters from `<id>.chapters.txt`;
  - tags from `youtube.tags`.
- [ ] Upload `<id>.vtt` as English (UK) captions. Set the thumbnail. Add to the
      playlist in `playlist`.
- [ ] Set `status: "published"` and `youtube.id` in `catalogue.json`.
- [ ] Add the video to the website: daybook-website `src/content/videos.json`:
  - slug, title, YouTube id, duration, transcript (from the script's voice-over
    column), chapters, `vertical`;
  - copy the thumbnail into its `public/`.

  `/demos/<vertical>` lists videos by `vertical`.
- [ ] Social: cut the vertical versions listed as `social` entries (`sources` names the
      parent video).
