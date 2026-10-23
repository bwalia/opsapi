# CMS public media (featured images on www)

Upload a featured image from OpsAPI UI and have it live on
`https://www.workstation.co.uk/…` without a workstation-website git PR.

## Flow

1. Editor opens a CMS post → **Featured image → Upload image**.
2. `POST /api/v2/cms/media` (cms:update) puts the file in the public website S3 bucket.
3. Response `url` is stored on the post as `featured_image_url`.
4. Save the post; trigger **Website updates** webhook (or wait for ISR) so the listing refreshes.

Object key when a slug is set:

```text
img/blog/<slug>/cover.<ext>
→ https://www.workstation.co.uk/img/blog/<slug>/cover.<ext>
```

Without a slug: `img/cms/<namespace>/<uuid>.<ext>`.

## Vault (WSL Vault)

Path: `workstation-opsapi/<ring>/config` (same ExternalSecret as the API).

| Key | Purpose |
|-----|---------|
| `CMS_PUBLIC_S3_ACCESS_KEY` | IAM access key with `s3:PutObject` on `workstation-website` |
| `CMS_PUBLIC_S3_SECRET_KEY` | Secret |
| *(or)* `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Same shape as website deploy |

Non-secret env (Helm `extraEnv` on workstation-int / workstation-prod):

| Key | Example |
|-----|---------|
| `CMS_PUBLIC_S3_BUCKET` | `workstation-website` |
| `CMS_PUBLIC_S3_REGION` | `eu-west-2` |
| `CMS_PUBLIC_BASE_URL` | `https://www.workstation.co.uk` |
| `CMS_PUBLIC_S3_ENDPOINT` | optional; default `https://s3.<region>.amazonaws.com` |

After adding Vault keys, wait for ESO (~1m) then restart **only** `deploy/workstation-opsapi` (explicit deployments list), or let Reloader roll it.

IAM should allow PutObject (and optionally PutObjectTagging) under `img/blog/*` and `img/cms/*` on bucket `workstation-website`. Do **not** grant DeleteBucket / broad `*`. The bucket’s existing public website / proxy policy already serves those keys as public GETs.

## API

```http
GET  /api/v2/cms/media/config
POST /api/v2/cms/media
Content-Type: multipart/form-data
file: <image>
slug: hybrid-execution-for-coding-agents   # optional
kind: cover                                 # optional
```

## Checklist after deploy

- [ ] Vault keys present; pod env shows `CMS_PUBLIC_S3_BUCKET` / access key SET (not values)
- [ ] Post editor shows **Upload image**
- [ ] Upload returns 201 with a www URL that GETs 200
- [ ] Save post + website webhook → listing card uses the image
