# Landlord File My Tax demo video

These Playwright recorders make the "100-property landlord files their 2025-26 return with AI" video on int, as a real browser session with on-screen captions. Long waits are sped up afterwards by `edit.py`.

## Inputs

Keep these in a private folder, `$SP`, never in this repo:

| File | What |
|---|---|
| `landlord_email`, `int_pw` | a member account on int (register a fresh one per full take) |
| `hmrc_user.json` (or `$HMRC_USER_FILE`) | an HMRC sandbox test taxpayer `{"data":{"userId","password","nino"}}`. Make one at https://int-opsapi.workstation.co.uk/hmrc-test-users. Each NINO can belong to only one OpsAPI account. |
| `landlord/pdf/*.pdf` | the 12 monthly statements: `python3 make_statements.py "$SP/landlord/pdf"` |

## Recorders

| Script | Films | Output |
|---|---|---|
| `record_landlord.mjs` | the whole journey: assistant setup, interest, upload, about 2 h of sorting, estimate, review question, then filing | `out/` |
| `record_ending.mjs` | only the filing ending (steps 9–14) for an account whose statements are already sorted | `out_end/` |
| `record_sorted.mjs` | how the AI sorted the lines, plus an accountant's corrections (1920×1080) | `out_sorted/` |

```bash
npm install && npx playwright install chromium
SP=/path/to/private node record_landlord.mjs
python3 -I edit.py "$PWD" out            # → out/landlord-file-with-ai.mp4
# re-film just the ending:
SP=... KUBECONFIG=... ./reset_ending.sh
SP=... HMRC_USER_FILE=hmrc_user_landlord.json node record_ending.mjs
python3 -I edit.py "$PWD" out_end 92.5   # optional end time, in raw seconds
```

`edit.py` plays each recorded wait longer than 8 s in 4 s (statement processing in 25 s). It drops `cut` segments and can stop at a given raw time, so parts can be joined with `ffmpeg -f concat`.

## Notes

- **One driver at a time.** Only one session should drive the demo account at once; two recorders on the same account undo each other's confirmations.
- **`reset_ending.sh`:**
  - Puts the account back to "sorted, nothing filed": flags the AI's unsure lines again, removes the NINO and disconnects HMRC.
  - It doesn't undo category changes made by `record_sorted.mjs`; put those back to `general_admin_expenses` first.
- **Filing a landlord return needs the Property Business API.** The HMRC sandbox application must be subscribed to Property Business (MTD); without it, HMRC answers 403 `RESOURCE_FORBIDDEN` at "Ask HMRC to work out my tax".
