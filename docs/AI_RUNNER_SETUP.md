# Setting up a machine for AI Runs

This runbook sets up a Mac or Linux machine to run AI coding agents on OpsAPI tasks. The design behind it is in `docs/AI_RUNNER.md`.

**No machine?** Every workspace also has the **built-in runner**, inside OpsAPI: turn on AI Runs and choose Start with AI on a task. It needs no setup to plan and write on tasks; to work in GitHub repositories, see [the built-in runner](#the-built-in-runner-no-machine) at the end. Use a machine when the agent must run code, builds or tests.

The machine runs **PromptPilot in runner mode**. It asks OpsAPI for work, so OpsAPI never connects to the machine and no port is opened. Each run happens in a git repo on the machine, on a new `ai/…` branch, never on `main`. The machine's own git and GitHub credentials push the branch and open the pull request.

## 1. What the machine needs
- `git`, and `gh` logged in (`gh auth login`) if runs should open pull requests.
- **Claude Code** (`claude`), signed in to the account whose Max plan pays for the runs. API keys are not used: the runner removes `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` from the agent's environment.
- Optionally `cursor-agent`. Cursor can't hand permission prompts to OpsAPI, so every Cursor run needs a manager's approval before it starts.
- Go 1.22 or newer to build PromptPilot.
- The repositories the agents will work in, cloned under one folder (for example `~/projects`).

## 2. Build PromptPilot
```sh
git clone https://github.com/bwalia/promptpilot ~/projects/promptpilot
cd ~/projects/promptpilot && git checkout feat/runner-mode   # until it is merged
go build -o promptpilot .
```
On macOS 26 with Go 1.22, use `go build -ldflags=-linkmode=external -o promptpilot .`. Without that flag, the binary stops at launch with "missing LC_UUID".

## 3. Claude login for unattended runs
A runner started as a service has no terminal, so give it a long-lived Max-plan token:
1. The account owner runs `claude setup-token` once and copies the token it prints.
2. Save the token without it showing on screen, readable only by you:
   ```sh
   mkdir -p ~/.config/promptpilot && pbpaste > ~/.config/promptpilot/claude-oauth.token
   chmod 600 ~/.config/promptpilot/claude-oauth.token
   ```
3. Point `claude_oauth_token_file` in `runner.json` at that file.

If the runner runs in your own logged-in session (a terminal, or the LaunchAgent below), Claude can use the normal login instead. Then you can leave `claude_oauth_token_file` out.

## 4. In OpsAPI (a workspace admin)
1. **My Workspace → Plugins:** turn on **AI Runs**.
2. **AI run settings:**
   - **Output:** pull request (the default), push a branch, or local commit only.
   - **Approval policy:** who decides permission requests (managers by default); whether runs started by an assignee need a manager's approval; the permission and input timeouts.
   - **Limits and safeguards:** open runs per person and per workspace, a daily token limit, the similar-work threshold, and log retention.
   - **Prompt template:** the text every run starts from.
3. **Runners → Register runner**, named after the machine (for example `mac-studio`). The token is shown **once**. Copy it and save it on the machine the same way:
   ```sh
   pbpaste > ~/.config/promptpilot/workstation.token && chmod 600 ~/.config/promptpilot/workstation.token
   ```
   If it is lost, use **Rotate token**. The old token stops working at once.

Roles: give people `ai_runs` (create to start runs on their tasks, manage for all runs), `ai_runs_approvals` (to decide requests), `ai_runners` (to manage machines) and `ai_runs_settings` as needed.

## 5. `runner.json`
Start from `runner.example.json`:
```json
{
  "registrations": [{
    "name": "mac-studio",
    "opsapi_url": "https://int-opsapi.workstation.co.uk",
    "token_file": "~/.config/promptpilot/workstation.token",
    "allowed_roots": ["~/projects"],
    "max_concurrency": 1
  }],
  "profiles": [ "… claude (asks before commands), cursor, fake-bridge for testing …" ],
  "claude_oauth_token_file": "~/.config/promptpilot/claude-oauth.token",
  "restore_branch": true
}
```
- **`allowed_roots`:** the only folders runs may work in. Git repos up to 3 levels below them appear in the Start dialog's folder picker.
- **Profiles:** keep the `claude` profile from the example. It runs Claude Code in stream-json mode with the runner as its permission host:
  - edits inside the folder are allowed;
  - anything else is asked in OpsAPI;
  - it has `--strict-mcp-config`, so your personal claude.ai connectors never reach the agent;
  - the runner refuses a `claude` profile without that flag.
- **Health:** a profile's `health` command (Claude: `claude auth status --json`) runs every few minutes. A logged-out agent shows as unavailable and takes no work. Its output, which includes your email, is never sent.

Check it:
```sh
./promptpilot runner -config runner.json -check
```

## 6. Run it
**Try it in a terminal first:**
```sh
./promptpilot runner -config runner.json
```
Within about 15 seconds, the runner shows as **Online** under Runners, and its repos are offered in Start with AI.

**As a service on macOS:** use a LaunchAgent in your GUI session. Claude and Cursor need the login keychain, which isn't unlocked over SSH.
```sh
sed "s|__HOME__|$HOME|g" deploy/com.promptpilot.runner.plist > ~/Library/LaunchAgents/com.promptpilot.runner.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.promptpilot.runner.plist
launchctl kickstart -k gui/$(id -u)/com.promptpilot.runner   # restart after a rebuild or config change
tail -f ~/Library/Logs/promptpilot-runner.log
```
On Linux, use the systemd user unit in `deploy/promptpilot-runner.service`; the runner README has the commands.

## 7. A first run
1. Give a task to yourself.
2. On the task, choose **Start with AI**, then pick the runner, the **fake-bridge** profile and a repo folder. Click **Preview**, then **Start**.
3. The run page shows **Needs your decision** for `npm test`. Click **Allow**.
4. The run ends **Succeeded**, with an `ai/<task>-…` branch pushed (or a PR, depending on the output setting). The folder is back on the branch it was on before.
5. Now try the **claude** profile on a small, real task.

## 8. Day to day
- **AI Runs:** every run and its status. **Waiting on you** lists the permission requests and approvals you may decide; the notification bell links to them too.
- **A run's page:** shows the prompt, a readable live log, the conversation (you can message the agent), the permission requests, usage, and Cancel / Retry.
- **Machines:** every session on every machine, including Claude or Cursor sessions started by hand. Check here before starting work in a folder someone is using. The runner also refuses a folder with a busy session.
- **Runners:** each profile's health and plan usage, for example "53% of the 7-day limit used".

## 9. Troubleshooting

| What you see | Why, and what to do |
|---|---|
| The runner stays **Offline** | Wrong `opsapi_url` or token file, or the token was rotated: save the new one and restart. A 404 in the runner log means AI Runs is turned off for the workspace. |
| A run stays **Queued** | The runner is offline or paused, it is already running `max_concurrency` runs, or the run's profile is unavailable. Check Runners. |
| A run stays **Needs approval** | A manager has to approve it (Cursor runs, or runs started by an assignee when that setting is on). |
| A run stays **Waiting for permission** | Someone allowed to decide has to answer. Unanswered requests are denied after the permission timeout. |
| The run fails with `dirty_folder` | The folder has uncommitted changes. Commit or stash them. |
| The run fails with `folder_busy` | A Claude or Cursor session is busy in that folder (see Machines). |
| The run fails with `bad_repo_path` | The folder isn't inside `allowed_roots`, or isn't a git repo. |
| A profile is unavailable: "not logged in" | Run `claude auth login`, or set up `claude_oauth_token_file` (section 3). |
| The run fails with `rate_limited` | The Max plan's usage window is used up. Runners shows when it resets; then Retry. |
| The run fails with `needs_input_timeout` | The agent asked a question and nobody answered in time. Retry, and answer on the run page. |
| Cursor says "keychain locked" | The runner was started over SSH. Run it as the LaunchAgent in the GUI session. |
| The build stops with "missing LC_UUID" | Use `-ldflags=-linkmode=external` (section 2). |

## Security notes
- The runner token belongs to one workspace. It is stored hashed, so treat the file like a password (mode 0600) and rotate it if it leaks.
- Agents never get `--dangerously-skip-permissions`. The runner refuses profiles that contain it.
- Some commands are denied by the runner without asking anyone:
  - `git push`/`merge`/`rebase`/`reset --hard`;
  - leaving the run's branch;
  - `sudo`;
  - `rm -r /` or `~`;
  - `curl | sh`;
  - keys and `.env` files;
  - any path outside the folder.
- Pushing and opening the PR are done by the runner itself, with the machine's credentials.
- The run-scoped token the agent uses for its task tools is valid only while that run is open, and only for its own task.

## The built-in runner (no machine)
Every workspace has a runner called **OpsAPI built-in**. It runs inside OpsAPI on an AI model: the workspace's own AI providers, else the platform's model (Ollama). It is always online, and Start with AI picks it when no machine is online. Design: `docs/AI_RUNNER.md` §28.

- **Without a repository** (Repository: *No repository*): it plans, answers and writes on the task, as comments and subtasks.
- **With GitHub:** it reads the code, commits to its own `ai/…` branch and opens a pull request. It can't run code or tests.
- **Limits** (platform settings): built-in runs at once (2 over all workspaces, 1 per workspace) and agent steps per run (40).
- **Turning it off for a workspace:** pause it under Runners & sources, or limit its Access.

### GitHub, once per platform (a platform admin)
1. On GitHub: Settings → Developer settings → GitHub Apps → **New GitHub App** (under the organisation that should own it).
   - **Callback URL** and **Setup URL:** the callback URL shown on AI Runs platform settings (`<dashboard>/dashboard/ai-runner/github`). Tick **Redirect on update**.
   - Leave **Request user authorization (OAuth) during installation** off, and the **webhook** inactive.
   - **Repository permissions:** Contents read and write, Pull requests read and write.
   - **Where can it be installed:** any account, if other organisations' workspaces should use it.
2. Create it, then **Generate a private key** (a `.pem` downloads) and **Generate a new client secret**.
3. In OpsAPI, **AI Runs platform settings → GitHub App:** App ID, App slug, Client ID, the client secret and the private key. Save. The key and the secret are stored sealed and never shown again.

For GitHub Enterprise Server, also set the API address (`https://<host>/api/v3`) and the web address (`https://<host>`).

### GitHub, per workspace (a runner manager)
1. **Runners & sources → Connect GitHub.** GitHub asks where to install the App and which repositories it may use.
2. GitHub sends you back to OpsAPI, then asks you to sign in to GitHub once, so OpsAPI can check you can reach that installation.
3. The repositories appear in the built-in runner's **Repository** list in Start with AI. **Connect another account or change repositories** goes back to GitHub; **Refresh repositories** reads them again; **Disconnect** removes an account from this workspace (uninstall the App on GitHub to remove it everywhere).

| What you see | Why, and what to do |
|---|---|
| "GitHub isn't set up on this server yet" | A platform admin adds the GitHub App (above). |
| "This GitHub sign-in expired or was started elsewhere" | Connect again from the same workspace, within 10 minutes. |
| "GitHub didn't confirm the installation" | Your GitHub account can't reach that installation: ask its owner, or install the App yourself. |
| "sent the install to an organisation owner for approval" | An organisation owner approves the App on GitHub; then Connect GitHub again. |
| The run fails with `pr_failed` | The changes are on the run's branch; the pull request couldn't open (the base branch is protected or missing). Open it by hand. |
| The run fails with `step_limit` | The task was too big for one run: split it, or raise the steps in platform settings. |
| The run fails with `model_error` | The model server didn't answer (busy or down): retry, or choose another AI model. |
