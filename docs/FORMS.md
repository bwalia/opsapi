# Forms

Build a form, publish it, and share its link. Anyone with the link can fill it in.
Each response is saved, and it can create a **customer**, a **lead** and/or an
**invitation to your workspace**.

- Dashboard: **Forms** in the sidebar (`/dashboard/forms`).
- Public page: `/f/<public_id>`.
- Design notes: [FORM_BUILDER_PLAN.md](FORM_BUILDER_PLAN.md).

## Contents
1. [Turning it on](#1-turning-it-on)
2. [Building a form](#2-building-a-form)
3. [Creating records from responses](#3-creating-records-from-responses)
4. [Publishing and sharing](#4-publishing-and-sharing)
5. [Responses](#5-responses)
6. [Insights](#6-insights)
7. [Emails and alerts](#7-emails-and-alerts)
8. [Webhooks](#8-webhooks)
9. [AI](#9-ai)
10. [API](#10-api)
11. [Limits, spam and privacy](#11-limits-spam-and-privacy)
12. [Configuration](#12-configuration)

## 1. Turning it on

Forms is the `forms` feature. It is included in the `all`, `business`, `field_service`, `ecommerce`,
`ecommerce_chat`, `collaboration`, `cms`, `academy`, `billing`, `hospital` and `property` presets.

It is **not** in `tax_copilot` or `core_only`. A deployment can still add it, because `forms`
is a feature-only code like `services`:

```
PROJECT_CODE=tax_copilot,services,forms
```

Who can do what is set by the RBAC module `forms`:

| Permission | Lets you |
|---|---|
| `forms.read` | See forms and their responses |
| `forms.create` | Create and duplicate forms |
| `forms.update` | Edit, publish, close, retry and mark responses as spam |
| `forms.delete` | Delete forms and responses |
| `forms.manage` | All of the above, plus the workspace's custom domain and spam-check (Turnstile) keys |

Workspace owners and admins get `forms` when the feature is installed.

## 2. Building a form

Open a form to get five tabs: **Build**, **Settings**, **Share**, **Responses** and **Insights**.

The **Build** tab has three areas:
- **Palette (left).** Click a field type to add it.
- **Canvas (middle).** Drag the handle to reorder questions. The arrow buttons do the same
  from the keyboard.
- **Field settings (right).** Edit the selected question.

Changes save automatically. If someone else saved the form in the meantime, the editor says so
and offers to reload instead of overwriting their change.

| Type | Notes |
|---|---|
| Short text, Paragraph | Optional minimum and maximum length |
| Number | Optional minimum, maximum and whole-numbers-only |
| Date, Time | Optional earliest and latest date |
| Dropdown, Single choice, Checkboxes | Options, one per line (pasting a list works). Checkboxes can require a minimum and maximum number of choices |
| Yes / No | Answering "No" counts as an answer |
| Rating | 1–5 stars or 1–10 |
| Name | First and last name |
| Email, Phone, Website | Format-checked |
| Address | Line 1, line 2, city, postcode, country |
| Consent | A statement the person ticks. A required consent must be ticked |
| Hidden | Filled from the link's query string, e.g. `?utm_campaign=autumn` |
| File upload | Up to 10 files of up to 10 MB each (you set both). Accepts images, documents, or either (see §11) |
| Heading, Text block | Display only; they don't take an answer |
| Page break | Starts a new step (see below) |

Every question has an **answer key**:
- It is made from the label, and follows the label until the question is published. After
  that it never changes.
- Webhooks, the CSV export and `{{answer_key}}` placeholders in the auto-reply all use it.

"**Copy the answer to the record's…**" (`maps_to`) puts an answer on the record the form creates:
- `phone`
- `company`
- `job_title`
- `address`
- `notes`
- `marketing_consent`

**Show a question only when…** (conditional logic). In a question's settings, add up to 10
conditions on the answers to questions **above** it, and choose whether all or any must hold:

| Condition | Works on |
|---|---|
| is / is not | any answer |
| is one of / is none of | choices |
| contains | text and checkboxes |
| more than / less than (after / before) | numbers, ratings and dates |
| is answered / is empty | any answer |

A hidden question isn't required, and its answer is dropped. The server applies the same rules
when the response arrives, so a visitor can't get around them. The name and email questions
locked by **Create records** can't have conditions, because records need them.

**Steps.** Each **Page break** starts a new step. Visitors see "Step 2 of 3" and a progress bar,
and **Next** checks the current step's required questions before moving on. A step whose
questions are all hidden by conditions is skipped.

## 3. Creating records from responses

The **Create records** card at the top of the Build tab has three options. The deployment
must have the module, and you need its permission:

| Option | Creates | Needs |
|---|---|---|
| Create a customer | A row in **Customers** | the `ecommerce` or `billing` feature, plus `customers.create` |
| Create a lead | A row in **Leads**, with source `form` plus the campaign and page it came from | the `crm` feature, plus `crm_accounts.create` |
| Invite them to this workspace | A **workspace invitation** with the role you choose | `users.create`, and you can only pick roles you could give yourself |

Ticking an option adds the **Name** and **Email** questions it needs and **locks** them:
- they are always required, can't be deleted, and keep their type;
- if the form already has an Email question, that one is used instead of adding a second.

When the option is turned off, the fields unlock again.

**What happens when someone submits:**
- **Existing record:** if a customer, lead or member already has that email in your workspace,
  the response is **linked** to it. That record is **never changed** by the response.
- **New email:** the record is created.
- **Two people at once:** if two people submit the same new email at the same moment, only one
  record is created and both responses link to it.
- **A step fails:** for example, the workspace is full. The response is still saved and marked
  **Needs attention**. Fix the cause, then press **Retry** on the response.
- **Invitations:** the person gets an email, and their account is created when they accept it
  and choose a password. That proves they own the address, so a form can't create accounts for
  other people's emails.
  - An email that already has an account accepts the invitation by signing in.
  - **Seats:** an invitation an admin sends from Members holds a seat while it is pending (like
    GitHub). A request that comes from a form holds none until the person accepts (like Slack).
    A request is created only while a seat is free, and accepting it needs a free seat too.
    Otherwise the person is told the workspace is full, and you see **Needs attention** with the
    reason "workspace full". Up to `max(50, 5 × the seat limit)` form requests can wait at once.
    They expire after 7 days, and Members marks them "Requested via a form".

Adding an option, or publishing a form that has one, needs that option's permission. Publishing
lets the public create those records on your behalf.

## 4. Publishing and sharing

**Publish** makes the current draft the live version:
- Later edits stay in the draft (shown as "Unpublished changes") until you publish again.
- Each response keeps the labels of the version it answered.

**Close** stops new responses; visitors see your closed message. **Reopen** starts them again.
The form also closes automatically on a set date, or after a set number of responses
(**Settings**).

**Delete** makes the link stop working at once. The form and its responses are removed after
30 days.

The **Share** tab has:
- **The link.** UTM tags on it (`?utm_source=…&utm_campaign=…`) are saved with each response and
  copied onto leads.
- **Put it on your website.** A two-line snippet. It loads the form in a frame that grows to fit
  it, and passes on the UTM tags in your page's link. The response records your site as its
  page.
- **QR code.** Download as PNG (1024 px) or SVG, for posters, flyers and events.
- **Prefilled link.** Fill in an answer in advance, e.g. `…/f/<id>?email=ada@example.com`. Text,
  number, date and choice questions can be prefilled; a choice must match one of its options.

**Branding** (**Settings → Branding**): the main colour (buttons, highlights), the page
background, a logo (an `https://` image address; empty uses the workspace logo) and the submit
button's text. Every form shows "Powered by OpsAPI"; for now no plan can hide it (§11).

**Embedding** works on any website. The dashboard sends `Content-Security-Policy: frame-ancestors *`
on public form pages (`/f/*`) only. Every other page sends `X-Frame-Options: SAMEORIGIN` and
`frame-ancestors 'self'`, so other sites can't frame the dashboard (clickjacking). A proxy in front
of the dashboard must not add its own `X-Frame-Options` to `/f/*`.

### Custom domain

**Forms → Custom domain** (needs `forms.manage`) puts the workspace's form links on its own
address, e.g. `https://forms.acme.com/f/<id>`. One domain per workspace.

1. Enter the domain. A subdomain such as `forms.acme.com` works best.
2. Add the two DNS records shown:

   | Type | Name | Value |
   |---|---|---|
   | CNAME | `forms.acme.com` | the platform's edge (`FORMS_DOMAIN_TARGET`); an `A` record if that is an IP address |
   | TXT | `_opsapi-challenge.forms.acme.com` | `opsapi-verify=<token>` |

3. **Check now**, or wait: pending domains are re-checked every hour for a week.

Both records must be found. The TXT record proves the domain is yours: the edge is shared with
other sites, so pointing a domain at it proves nothing. If a second workspace proves control of
the same domain, the domain moves to it, and the first workspace sees why.

Once connected:
- share links, the embed code, the QR code and the agent use the domain. Links shared before keep
  working;
- the domain serves **only this workspace's forms**. The public API refuses requests for other
  workspaces' forms from that origin, and the dashboard answers 404 there for everything except
  `/f/*`;
- connected domains are re-checked daily. If the records disappear, the domain goes back to
  pending and links return to the dashboard's address instead of breaking.

DNS tips: on Cloudflare, set the record to **DNS only** (grey cloud). A root domain (`acme.com`)
can't have a CNAME, so use the provider's ALIAS/ANAME record or a subdomain.

**For the platform operator:** custom domains are off until `FORMS_DOMAIN_TARGET` is set (§12).
The edge must then:
1. route those hosts to the dashboard, passing the customer's host as `X-Original-Host` (or
   keeping it as `Host` / `X-Forwarded-Host`);
2. get a certificate for each one. Ask `GET /api/v2/public/form-domains/check?domain=<host>` before
   issuing it: **200** means it is a connected domain. This is the hook for Caddy's
   `on_demand_tls ask` or lua-resty-auto-ssl's `allow_domain`.

**On wslproxy** (bwalia/wslproxy#1317, "on-demand hosts"), both steps are one setting. On the
dashboard's server, set **On-demand hosts: ask URL** to
`https://<api host>/api/v2/public/form-domains/check`, and set `FORMS_DOMAIN_TARGET` to the name
customers should CNAME to (the edge's POP name). A connected domain then gets its certificate on
its first visit and reaches the dashboard with `X-Original-Host`.

A deployment on its own address (e.g. a single-workspace dashboard at `my.example.com`) needs
none of this: its links already use that address.

## 5. Responses

The **Responses** tab lists responses newest first, with search, a status filter and
**Export CSV**. Open a response to see:
- every answer, with the labels it was answered under;
- the records it created or linked;
- where it came from, and how long it took to fill in.

| Status | Meaning |
|---|---|
| Complete | Saved, and every record step worked |
| Needs attention | A record step failed; see the reason, then **Retry** |
| Spam | It failed the bot checks. No records were made and no emails sent. **Not spam** processes it now |

**Files** are listed with each response. **Open** gets a link that works for 10 minutes; files
are never public.

**On a customer's or lead's page**, the **Form responses** panel lists every response linked to
that record, with its answers.

Deleting a response removes its answers and files for good. Customers, leads and invitations it
created stay.

The CSV export is streamed. Cells that start with `=`, `+`, `-`, `@` or a tab get a leading `'`,
so spreadsheets don't run them as formulas.

## 6. Insights

The **Insights** tab shows, for the last 7, 30 or 90 days, or the last year:

| Figure | Meaning |
|---|---|
| Views | The form was opened |
| Started | The visitor answered a first question. "% finished" = responses ÷ starts |
| Responses | Responses received (spam left out). "% of views" = responses ÷ views |
| Time to fill in | The average time from opening the form to sending it |

There is also a chart per day, **Where people stop** (how many reached each step of a
multi-step form), and **Where responses come from** (the UTM source, else the referring site,
else "direct").

Views, starts and steps are counted in each server's memory and saved every 30 seconds, so a
busy form costs one database write per server per 30 seconds. A restart can lose up to 30
seconds of these counts. Responses are always exact.

**Summarise with AI** adds exact counts for every choice, rating and number question, and a
short summary written by AI from the free-text answers of the latest 500 responses. The AI never
sees the name, email, phone or address answers.

## 7. Emails and alerts

**In the app.** The form's creator, plus any **Settings → Emails** addresses that are members of
the workspace, get a notification (the bell) for each response. Turn it off in **Settings →
Alerts**.

**In chat.** Pick one of the workspace's chat channels in **Settings → Alerts**. Each response
posts its first six answers there, with a link to it.

The emails are sent from the event outbox, so they are retried and survive a restart. Each one is
sent at most once per response.

- **New-response alert:** goes to the addresses in **Settings → Emails**, or to the person who
  created the form if none are set.
- **Auto-reply:** goes to the email the person gave. Use `{{answer_key}}` to include an answer.
  Answers are inserted as text, never as HTML.
- **Invitation:** goes out for each invitation a response creates. A repeat response from the
  same email doesn't send another.

Each workspace can use its own SMTP server. The workspace owner sets it up in **Workspace →
Email** (`/dashboard/namespace/email`): host, port, security, login (the password is stored
encrypted) and the sender. **Send test** checks it. Without one, the platform's server is used.
**Forms → Settings → Emails** says which applies, and warns when no email can be sent. You can
change the wording of each email in Workspace → Email:
- `forms.new_response`
- `forms.auto_reply`
- `namespace.invitation`

The invitation email is also sent by **Members → Invite** now.

## 8. Webhooks

Responses are the `form.submission` entity in **Workspace → Webhooks**:

| Event | When |
|---|---|
| `form.submission.created` | A response arrives. Check `status`: spam is delivered too, with `status: "spam"` |
| `form.submission.updated` | Its status changed, or it was retried |
| `form.submission.needs_attention` | A record step failed |
| `form.submission.deleted` | A response was deleted |

The payload's `data` is the answers, keyed by answer key. Responses are personal data from the
public, so they are left out of the audit trail on purpose.

## 9. AI

**Draft a form.** **New form → Describe it, AI drafts it.** Describe the form in a sentence. The
draft is shown first (questions, and the records it would create), and nothing is saved until
you press **Create this form**. Each question is checked like one you'd add yourself. Any that
don't pass are left out, and the draft says how many. Record options are kept only if this
deployment has them and you're allowed to use them.

**Summarise responses.** See §6.

**The assistant** (Ask AI on the Forms page, and the chat agent) has these tools:

| Tool | What it does |
|---|---|
| `create_form` | Always makes a **draft**; you review it before publishing |
| `list_forms` | Lists the workspace's forms |
| `get_form` | Shows one form |
| `update_form` | Changes the draft: title, description, add or remove questions, make them required, and the records it creates. Live only after `publish_form` |
| `publish_form` | **Asks you to confirm** before making a form public |
| `summarize_form_responses` | The counts and AI summary from §6 |

It goes through the same checks as the builder: locked contact fields, permissions and limits.
Every AI call is metered under the feature `forms` (Activity → AI usage), and counts towards
`AI_USER_DAILY_TOKEN_LIMIT`.

Example: "Create a job application form with name, email, CV link and years of experience, and
make each applicant a lead."

## 10. API

### Admin

Admin routes need `Authorization: Bearer <JWT or API key>` and `X-Namespace-Id`, and are guarded
by the `forms` permissions above. Bodies are JSON.

| Method | Path | |
|---|---|---|
| GET | `/api/v2/forms?status=&q=&cursor=&limit=` | List, newest first. `meta.next_cursor` pages on |
| POST | `/api/v2/forms` | Create a draft: `{title, description, template, fields, targets, settings}` |
| GET | `/api/v2/forms/targets` | The create-record options here, and the roles you may give |
| GET | `/api/v2/forms/templates` | Starter forms |
| GET | `/api/v2/forms/{uuid}` | Draft fields, settings, share URL, published answer keys |
| PUT | `/api/v2/forms/{uuid}` | Partial update. `expected_updated_at` gives **409** if it changed meanwhile |
| DELETE | `/api/v2/forms/{uuid}` | Delete |
| POST | `/api/v2/forms/{uuid}/publish`, `/close`, `/reopen`, `/duplicate` | |
| GET | `/api/v2/forms/{uuid}/submissions?status=&from=&to=&q=&cursor=&limit=` | Responses. `meta.columns` lists every answer key across versions |
| GET | `/api/v2/forms/{uuid}/submissions/{sid}` | One response, with the fields it answered |
| PUT | `/api/v2/forms/{uuid}/submissions/{sid}` | `{status: "spam" \| "complete"}` |
| POST | `/api/v2/forms/{uuid}/submissions/{sid}/retry` | Re-run failed record steps |
| DELETE | `/api/v2/forms/{uuid}/submissions/{sid}` | Delete a response |
| GET | `/api/v2/forms/{uuid}/export` | CSV, streamed |
| GET | `/api/v2/forms/{uuid}/submissions/{sid}/files/{file}` | `{url}`: a signed link to the file, valid 10 minutes |
| GET | `/api/v2/forms/{uuid}/analytics?days=` | Insights (1–365 days, default 30) |
| POST | `/api/v2/forms/{uuid}/summary` | Counts plus the AI summary. `?numbers_only=true` skips the AI |
| POST | `/api/v2/forms/generate` | `{prompt}` → a draft `{title, description, fields, targets, dropped}`. Nothing is saved |
| GET | `/api/v2/forms/responses?entity_type=&entity_uuid=` | Responses linked to a record (`customer`, `lead`, `user` or `invitation`) |
| GET / PUT | `/api/v2/forms/workspace-settings` | Turnstile keys. `PUT` needs `forms.manage`; the secret is write-only |
| GET | `/api/v2/forms/domain` | The custom domain: `{available, target, domain?, status, records, last_error?}` |
| PUT | `/api/v2/forms/domain` | `{domain}`: connect (replaces the current one) and check DNS. Needs `forms.manage` |
| POST | `/api/v2/forms/domain/check` | Check DNS now (10 a minute). Needs `forms.manage` |
| DELETE | `/api/v2/forms/domain` | Disconnect. Needs `forms.manage` |

`targets` is a list such as `[{"type": "customer"}, {"type": "lead"}, {"type": "user", "role": "member"}]`.

### Public (no login; any origin)

| Method | Path | |
|---|---|---|
| GET | `/api/v2/public/forms/{public_id}` | The live version's fields, `theme`, `captcha.site_key` (when on) and a `render_token`. **404** if unpublished, deleted or the workspace is suspended. **410** if closed |
| POST | `/api/v2/public/forms/{public_id}/uploads?field={key}` | Multipart `file`, header `X-Render-Token`. Returns **201** `{id, name, size, type}`; send the `id`s as the field's answer |
| POST | `/api/v2/public/forms/{public_id}/events` | `{type: "start"}` or `{type: "step", step: n}`. Always **204** |
| POST | `/api/v2/public/forms/{public_id}/submissions` | Header `Idempotency-Key`. Body `{answers, render_token, _hp: "", captcha_token?, context: {page_url, referrer, utm, duration_ms}}`. Returns **201** `{message, redirect_url?}`, **400** `{errors: {key: message}}`, **409** (full, or the monthly plan limit), **410** (closed), **413** or **429** |
| GET | `/api/v2/public/form-domains/check?domain={host}` | For the edge: **200** if the host is a connected custom domain, else **404** |
| GET | `/api/v2/public/invitations/{token}` | The invitation behind an email link |
| POST | `/api/v2/public/invitations/{token}/accept` | `{first_name, last_name, password}`: create the account and join (emails without an account) |

To post from your own website, read the form with the GET first. The `render_token` it returns
must be at least 2 seconds old when you submit (see §10).

## 11. Limits, spam and privacy

**Size limits:**
- 200 questions per form, 500 options per question.
- 64 KB per response, 1,000 forms per workspace.

**Rate limits** (shared by every pod through Redis):

| Who | Limit |
|---|---|
| One visitor (IP) on one form | 5 responses a minute |
| One visitor across all forms | 30 responses an hour |
| One form, all visitors together | 600 responses a minute |
| One visitor's uploads | 30 a minute, 300 an hour |

**Bot checks:**
- a hidden honeypot field;
- the `render_token`, which must be 2 seconds to 24 hours old.

A response that fails them is answered as if it worked, then kept as spam for 30 days. No
records are made and no emails sent.

**"I'm not a robot" check** (Cloudflare Turnstile), for forms that attract spam anyway:
1. A workspace owner or admin adds the site key and secret in **Forms → Spam protection**. The
   secret is stored encrypted and is never shown again.
2. Turn it on per form in **Settings → Spam protection**.

The check fails closed: if Cloudflare can't be reached, the response is refused and the visitor
can try again.

**Files:**
- The type is decided by the file's extension, whatever the browser says: images (`jpg`, `jpeg`,
  `png`, `gif`, `webp`, `heic`, `heif`) and documents (`pdf`, `txt`, `csv`, `doc(x)`, `xls(x)`,
  `ppt(x)`).
- SVG and HTML are never accepted, because they can carry scripts.
- A file is uploaded when it's picked, and is attached when the response is sent. Files never
  attached are deleted after 24 hours. A deleted response's files are deleted by the hourly
  clean-up.

**Plan limits:** a workspace's plan can cap its forms, its responses per month, and whether it
may hide "Powered by OpsAPI" (`lapis/lib/forms/limits.lua`). **For now everything is free:** no
plan has limits, and no plan may hide "Powered by OpsAPI". A setting saved earlier that hides it
is ignored.

**Privacy:**
- The visitor's IP is stored only as a keyed hash.
- **Settings → Keep responses** deletes responses after a number of days. Spam is always deleted
  after 30 days.

**Search** reads the form's responses in full. That takes about 1.5 s on a form with a million
responses.

## 12. Configuration

| Setting | Why |
|---|---|
| `FRONTEND_URL` | The dashboard's address. Used in emails (invitation and "view response" links) when the request didn't come from a known dashboard origin |
| SMTP (`SMTP_*` or the workspace's own server) | No SMTP means no emails. Responses and records still work |
| `JWT_SECRET_KEY` | Also signs render tokens and hashes IPs |
| Redis | Rate limits shared across pods. Without it, each pod counts on its own |
| MinIO (`MINIO_*`) | File uploads. Without it, an upload is refused with "File uploads aren't available right now." |
| `AI_PROVIDER`, `AI_MODEL`, `AI_API_KEY` | AI drafts and summaries (same settings as the chat agent). If no model answers, a draft shows an error and a summary shows only the counts; everything else works |
| `OPENSSL_SECRET_KEY`, `OPENSSL_SECRET_IV` | Encrypt the Turnstile secret |
| `TURNSTILE_VERIFY_URL` | Tests only: a stand-in for Cloudflare's check |
| `FORMS_DOMAIN_TARGET` | The edge that custom domains point at (a host name for a CNAME, or an IP for an A record). Unset = custom domains are off |
| `DOMAIN_VERIFY_RESOLVERS` | DNS servers the domain check asks (default `1.1.1.1,8.8.8.8`) |
