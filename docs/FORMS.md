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
6. [Emails](#6-emails)
7. [Webhooks](#7-webhooks)
8. [The AI assistant](#8-the-ai-assistant)
9. [API](#9-api)
10. [Limits, spam and privacy](#10-limits-spam-and-privacy)
11. [Configuration](#11-configuration)

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

Workspace owners and admins get `forms` when the feature is installed.

## 2. Building a form

Open a form to get four tabs: **Build**, **Settings**, **Share** and **Responses**.

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
| Heading, Text block | Display only; they don't take an answer |

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

The **Share** tab has the link. UTM tags on the link (`?utm_source=…&utm_campaign=…`) are saved
with each response and copied onto leads.

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

Deleting a response removes its answers for good. Customers, leads and invitations it created
stay.

The CSV export is streamed. Cells that start with `=`, `+`, `-`, `@` or a tab get a leading `'`,
so spreadsheets don't run them as formulas.

## 6. Emails

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

## 7. Webhooks

Responses are the `form.submission` entity in **Workspace → Webhooks**:

| Event | When |
|---|---|
| `form.submission.created` | A response arrives. Check `status`: spam is delivered too, with `status: "spam"` |
| `form.submission.updated` | Its status changed, or it was retried |
| `form.submission.needs_attention` | A record step failed |
| `form.submission.deleted` | A response was deleted |

The payload's `data` is the answers, keyed by answer key. Responses are personal data from the
public, so they are left out of the audit trail on purpose.

## 8. The AI assistant

On the Forms page, and in chat, the assistant has these tools:

| Tool | What it does |
|---|---|
| `create_form` | Always makes a **draft**; you review it before publishing |
| `list_forms` | Lists the workspace's forms |
| `get_form` | Shows one form |
| `publish_form` | **Asks you to confirm** before making a form public |

It goes through the same checks as the builder: locked contact fields, permissions and limits.

Example: "Create a job application form with name, email, CV link and years of experience, and
make each applicant a lead."

## 9. API

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

`targets` is a list such as `[{"type": "customer"}, {"type": "lead"}, {"type": "user", "role": "member"}]`.

### Public (no login; any origin)

| Method | Path | |
|---|---|---|
| GET | `/api/v2/public/forms/{public_id}` | The live version's fields and a `render_token`. **404** if unpublished, deleted or the workspace is suspended. **410** if closed |
| POST | `/api/v2/public/forms/{public_id}/submissions` | Header `Idempotency-Key`. Body `{answers, render_token, _hp: "", context: {page_url, referrer, utm, duration_ms}}`. Returns **201** `{message, redirect_url?}`, **400** `{errors: {key: message}}`, **409** (full), **410** (closed), **413** or **429** |
| GET | `/api/v2/public/invitations/{token}` | The invitation behind an email link |
| POST | `/api/v2/public/invitations/{token}/accept` | `{first_name, last_name, password}`: create the account and join (emails without an account) |

To post from your own website, read the form with the GET first. The `render_token` it returns
must be at least 2 seconds old when you submit (see §10).

## 10. Limits, spam and privacy

**Size limits:**
- 200 questions per form, 500 options per question.
- 64 KB per response, 1,000 forms per workspace.

**Rate limits** (shared by every pod through Redis):

| Who | Limit |
|---|---|
| One visitor (IP) on one form | 5 responses a minute |
| One visitor across all forms | 30 responses an hour |
| One form, all visitors together | 600 responses a minute |

**Bot checks:**
- a hidden honeypot field;
- the `render_token`, which must be 2 seconds to 24 hours old.

A response that fails them is answered as if it worked, then kept as spam for 30 days. No
records are made and no emails sent.

**Privacy:**
- The visitor's IP is stored only as a keyed hash.
- **Settings → Keep responses** deletes responses after a number of days. Spam is always deleted
  after 30 days.

**Search** reads the form's responses in full. That takes about 1.5 s on a form with a million
responses.

## 11. Configuration

| Setting | Why |
|---|---|
| `FRONTEND_URL` | The dashboard's address. Used in emails (invitation and "view response" links) when the request didn't come from a known dashboard origin |
| SMTP (`SMTP_*` or the workspace's own server) | No SMTP means no emails. Responses and records still work |
| `JWT_SECRET_KEY` | Also signs render tokens and hashes IPs |
| Redis | Rate limits shared across pods. Without it, each pod counts on its own |
