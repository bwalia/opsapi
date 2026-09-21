# Use your OpsAPI tasks from Claude Code (or any AI agent)

This lets your AI assistant see **your** OpsAPI kanban tasks, log time on them,
and attach a PR link — just by asking in plain English, e.g. *"what are my tasks
today?"*

You set this up **once**. It's two parts:

- **Part A** — make a *personal* API key, so the assistant acts as **you**.
- **Part B** — connect the assistant to OpsAPI.

Total time: about 5 minutes.

> This is the plain-English guide. For the full technical reference (every tool,
> scopes, env vars), see [README.md](README.md).

---

## Part A — Make your personal API key

Do this in the OpsAPI **dashboard**.

1. Sign in to the dashboard.
2. Go to **Namespace → API keys → New**.
3. Give the key a name you'll recognise, e.g. `Alice — Claude Code`.
4. Find **"Act as a team member"** and **search for your name, then click it.**
   > ⚠️ **This is the most important step.** It's what makes the key act as *you*
   > and see *your* tasks. If you skip it, the key sees nothing.
5. Under **Permissions**, switch on:
   - **Kanban** → `Read` and `Update`
   - **Projects** → `Read`
6. Click **Create key**.
7. **Copy the key** (it starts with `opsk_`). You only see it **once** — paste it
   somewhere safe for the next part.
8. **Check it worked:** back on the key list, your key should have a blue
   **"Personal"** badge next to its name.
   > No badge? You missed step 4. Delete the key and make a new one.

---

## Part B — Connect it to Claude Code

You need **Node.js** installed on your computer.

**1. Build the connector (one time):**

```bash
cd mcp
npm install
npm run build
```

**2. Register it** — copy this, and fill in **your key** and the **full path** to
this folder:

```bash
claude mcp add opsapi-kanban -s user \
  -e OPSAPI_URL=https://int-opsapi.workstation.co.uk \
  -e OPSAPI_API_KEY=opsk_your_key_here \
  -e OPSAPI_NAMESPACE=2 \
  -- node /full/path/to/opsapi/mcp/dist/index.js
```

> **The three values explained:**
> - `OPSAPI_URL` — your OpsAPI address (the one above is the int/workstation server).
> - `OPSAPI_API_KEY` — the `opsk_…` key you copied in Part A.
> - `OPSAPI_NAMESPACE` — the **number** of your workspace (e.g. `2`), **not** its name.

**3. Check it connected:**

```bash
claude mcp list
```

You should see `opsapi-kanban … ✔ Connected`.

**4. Start a *new* Claude Code session.**
The assistant only picks up new tools when it starts, so close the current one
and open a fresh window/session.

---

## Now just ask

In the new session, talk to the assistant normally:

- *"What are my tasks today?"*
- *"Log 30 minutes on task #2, note: fixed the login bug."*
- *"Add the PR link https://github.com/org/repo/pull/45 to task #1 and mark it done."*
- *"Show me the details of task #3."*
- *"Comment on task #1: waiting on review."*

**What it can do:** list your tasks · show one task · log time · attach a PR link ·
complete a task · add a comment.

---

## If something isn't working

| Problem | Fix |
|---|---|
| It says you have **no tasks**, but you do | Your key is probably a *machine* key. Check for the **"Personal"** badge (Part A, step 8). If it's missing, make a new key with **"Act as a team member"** selected. |
| `not valid for the requested namespace` | Use the workspace **number** for `OPSAPI_NAMESPACE` (e.g. `2`), not its name. |
| The new tools **don't show up** | Start a **fresh** Claude Code session (Part B, step 4). |
| You want to **change or rotate** the key | Make a new key, then run the same `claude mcp add …` command with the new key — it replaces the old one. |
| You want to **remove** it | `claude mcp remove opsapi-kanban -s user` |

---

## Notes

- **Who can make keys:** only a workspace **owner** (or a platform admin), and
  only for members of their own workspace.
- **Any agent, not just Claude Code:** the same `command` / `args` / `env` work in
  any MCP-compatible client (Claude Desktop, Cursor, …). See [README.md](README.md).
- **Keep your key private** — it acts as you. If it leaks, delete it in the
  dashboard and make a new one.
