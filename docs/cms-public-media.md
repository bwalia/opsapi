# CMS public media (images on www)

Upload images from OpsAPI Content (featured + in-body) and have them live on
`https://www.workstation.co.uk/…` without a workstation-website git PR.

## Flow

1. Open a CMS post or page in OpsAPI.
2. **Featured image → Upload image**, or in the content editor use the image
   button / paste / drop a file.
3. `POST /api/v2/cms/media` (cms:update) puts the file in the public website S3 bucket.
4. Featured: response `url` → `featured_image_url`. Body: TipTap inserts `<img src="…">`.
5. Save the post; trigger **Website updates** webhook (or wait for ISR) so listings refresh.

Object keys when a slug is set:

```text
img/blog/<slug>/cover.<ext>              # featured
img/blog/<slug>/inline-<id>.<ext>        # in-body (unique per upload)
→ https://www.workstation.co.uk/img/blog/<slug>/…
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
- [ ] Post editor shows **Upload image** under Featured image
- [ ] Content toolbar image button uploads (not URL-only) and inserts a www URL
- [ ] Upload returns 201 with a www URL that GETs 200
- [ ] Save post + website webhook → listing card / article body uses the image
