# Use your OpsAPI tasks and website content from Claude Code (or any AI agent)

This lets your AI assistant see **your** OpsAPI kanban tasks, create and update
tasks, log time and attach a PR link — and write and publish your workspace's
blog posts and pages — just by asking in plain English, e.g.
*"what are my tasks today?"* or *"draft a blog post about our new opening hours"*.

You set this up **once**. It's two parts:

- **Part A** — get a *personal* API key, so the assistant acts as **you**.
- **Part B** — connect the assistant to OpsAPI.

Total time: about 5 minutes.

> This is the plain-English guide. For the full technical reference (every tool,
> scopes, env vars, the HTTP service), see [README.md](README.md).

---

## Part A — Get your personal API key

The quickest way is the self-service page: open your avatar menu → **My API keys**
(`/dashboard/settings/api-keys`), press **Create key**, keep the **AI agent (MCP)** preset
(read, create and update tasks — or **Read only** for an agent that may look but not change anything,
or **Website content** to write and publish posts and pages; all are limited to what your own role
allows), copy the key — it is shown only once — and go
to Part B. The same page shows your workspace's numeric id for `OPSAPI_NAMESPACE` and
ready-to-paste setup for Claude Code and Cursor.

Otherwise a workspace **owner** makes it for you in the **dashboard**:

1. Sign in to the dashboard.
2. Go to **Namespace → API keys → New**.
3. Give the key a name you'll recognise, e.g. `Alice — Claude Code`.
4. Find **"Act as a team member"** and **search for your name, then click it.**
   > ⚠️ **This is the most important step.** It's what makes the key act as *you*
   > and see *your* tasks. If you skip it, the key sees nothing.
5. Under **Permissions**, switch on:
   - **Kanban** → `Read`, `Create` and `Update`
   - **Projects** → `Read`
6. Click **Create key**.
7. **Copy the key** (it starts with `opsk_`). You only see it **once** — paste it
   somewhere safe for the next part.
8. **Check it worked:** back on the key list, your key should have a blue
   **"Personal"** badge next to its name.
   > No badge? You missed step 4. Delete the key and make a new one.

---

## Part B — Connect it to Claude Code

Pick **one** of the two options.

### Option 1 — Your team runs the OpsAPI MCP service (easiest)

If your team gave you an MCP address (it ends in `/mcp`), you only need your key:

```bash
claude mcp add --transport http opsapi https://mcp.example.com/mcp \
  --header "Authorization: Bearer opsk_your_key_here" -s user
```

Replace the address with the one you were given. Nothing to install.
(Whoever runs the service sets `MCP_HOST` to that address's host name; see
[README.md](README.md#run-it-streamable-http).)

### Option 2 — Run it on your own computer

You need **Node.js 20 or newer**.

**1. Build the connector (one time):**

```bash
cd mcp
npm ci
npm run build
```

**2. Register it** — fill in **your key** and the **full path** to this folder:

```bash
claude mcp add opsapi -s user \
  -e OPSAPI_URL=https://int-opsapi.workstation.co.uk \
  -e OPSAPI_API_KEY=opsk_your_key_here \
  -- node /full/path/to/opsapi/mcp/dist/index.js
```

> **The values explained:**
> - `OPSAPI_URL` — your OpsAPI address (the one above is the int/workstation server).
> - `OPSAPI_API_KEY` — the `opsk_…` key you copied in Part A.
> - Optional: `-e OPSAPI_NAMESPACE=2` — the **number** (or uuid) of your
>   workspace, **never its name/slug**. Usually not needed: the key already
>   knows its workspace.
> - Optional: `-e OPSAPI_DASHBOARD_URL=https://int-opsapi-ui.workstation.co.uk`
>   to get clickable task links.

Already set up under the old name `opsapi-kanban`? It keeps working; rebuild
(`npm run build`) to get the new tools.

### Then (both options)

**Check it connected:**

```bash
claude mcp list
```

You should see `opsapi … ✔ Connected`.

**Start a *new* Claude Code session.** The assistant only picks up new tools
when it starts.

**Cursor:** add the same thing to `~/.cursor/mcp.json` — see
[README.md](README.md#run-it-streamable-http) for both forms.

---

## Now just ask

- *"What are my tasks today?"* · *"What's overdue?"* · *"My high-priority tasks this week."*
- *"Create a task in Website Redesign: fix the login redirect, high priority, due Friday, assign alice@acme.com."*
- *"Move task #12 to In Progress."*
- *"Set task #3 to review and note the branch feat/login-fix in its metadata."*
- *"Find tasks about invoices."*
- *"Log 30 minutes on task #2, note: fixed the login bug."*
- *"Add the PR link https://github.com/org/repo/pull/45 to task #1 and mark it done."*

**What it can do:** list your tasks (today, overdue, this week, by priority) ·
show a task · list projects and boards · create, update, move and search tasks ·
log time · attach a PR link · complete a task · comment.

With a **Website content** key:

- *"Draft a blog post about our spring opening hours, in the News category."*
- *"Publish that post and update the website."*
- *"Take the 'Summer sale' post off the website."*
- *"Upload ~/Pictures/team.jpg and use it as the About page's image."*

**What it can do:** list, read, create, edit, publish and unpublish blog posts and
pages · list categories and tags, create a category · upload images · tell the
website to update. It never deletes content.

---

## If something isn't working

| Problem | Fix |
|---|---|
| It says you have **no tasks**, but you do | Your key is probably a *machine* key. Check for the **"Personal"** badge (Part A, step 8). If it's missing, make a new key with **"Act as a team member"** selected. |
| `not valid for the requested namespace` / 403 | Use the workspace **number** or uuid for `OPSAPI_NAMESPACE` (e.g. `2`), never its name — or leave it out. |
| `401 Unauthorized` (Option 1) | The header must be exactly `Authorization: Bearer opsk_…`. Check the key wasn't revoked. |
| "requires an editor role" | You can read the project but not change it; ask a project admin to make you a member. |
| The new tools **don't show up** | Start a **fresh** Claude Code session. |
| You want to **change or rotate** the key | Make a new key, run the same `claude mcp add …` command with it (it replaces the old entry), then delete the old key. |
| You want to **remove** it | `claude mcp remove opsapi -s user` |

---

## Notes

- **Keep your key private** — it acts as you, and everything the assistant does
  is recorded in your name. If it leaks, delete it in the dashboard and make a
  new one; the old one stops working at once.
- **Any agent, not just Claude Code:** Cursor, Claude Desktop and other MCP
  clients work the same way. See [README.md](README.md).
