# Runbook: VAT returns (HMRC MTD)

What to do when a VAT return doesn't go through. The code is in `lapis/queries/VatFilingQueries.lua`, `lapis/lib/hmrc-vat-client.lua`, and the VAT page at `/dashboard/tax/vat`.

## Where to look

- **Alerts:**
  - `VatReturnNotFiled` fires when a return was rejected or HMRC was unreachable.
  - `VatFilingMostlyFailing` fires when most attempts are failing for an hour.
  - Both come from the metric `vat_submissions_total{result, environment}`.
- **The return:** `vat_returns` row. Check `status` (`draft`, `submitting`, `submitted` or `failed`) and `hmrc_receipt`, which holds HMRC's receipt, or the error with HMRC's body and HTTP status.
- **API logs:** search the opsapi pod logs for `[hmrc]` and `VAT`.

## Situations

| What you see | Meaning | What to do |
|---|---|---|
| `failed` with `unreachable` (no HTTP status) | We never got HMRC's answer, so we don't know if the return arrived | Open the period's **View return from HMRC** (`GET /api/v2/vat/hmrc/returns/:period_key`). If HMRC has it with our figures, mark ours filed by filing again (a duplicate with matching figures is recorded as filed). If HMRC doesn't have it, file again. |
| `DUPLICATE_SUBMISSION` | HMRC already has a return for the period | Handled automatically when HMRC's copy matches ours. If it doesn't match, someone filed different figures (another software, or the business itself). Never file again; correct it on the next return or with VAT652 (Notice 700/45). |
| `TAX_PERIOD_NOT_ENDED` | The period hasn't ended | Wait until after the period end. |
| `INVALID_REQUEST` or `INVALID_PAYLOAD` | HMRC rejected the figures | Our own checks (`Return.validate`) should have caught this, so treat it as a bug. Compare the `request` box values with HMRC's rules in the client spec. |
| `CLIENT_OR_AGENT_NOT_AUTHORISED` | The HMRC sign-in isn't for that VAT number | The person must connect to HMRC with the Government Gateway for that VRN, or the VRN on the VAT page is wrong. |
| `RESOURCE_FORBIDDEN` | The HMRC application isn't subscribed to VAT (MTD) | Subscribe it in the HMRC Developer Hub (sandbox or production app). |
| `VAT_SCOPE_MISSING` (409) | The HMRC connection was made without VAT | Connect to HMRC again from the VAT page; that asks for `read:vat write:vat`. |
| `VAT_FILING_OFF` (503) | `VAT_FILING_ENABLED` isn't `true` in production | Intended until go-live. Set it in the values file when approved. |
| Many failures across users | HMRC outage, or a bad release | Check https://api.service.hmrc.gov.uk/api-documentation/docs/api-statuses. If it's our release, roll back. To stop filing while you investigate, set `VAT_FILING_ENABLED=false` and redeploy values. Drafts are kept. |
| A row stuck in `submitting` for minutes | The pod restarted mid-filing | Treat it as `unreachable`: check HMRC's copy first, then set the row to `failed` (SQL) so a new draft can be made. |

## Never

- Delete a `submitted` return or its lines. Records must be kept for 6 years, and the inspection export (`/api/v2/vat/returns/:uuid/export`) depends on them.
- File a second return for a period HMRC already has. Corrections go on a later return (within the Notice 700/45 limit) or on form VAT652.
