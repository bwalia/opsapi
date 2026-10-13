---
title: AI Runs
pages: /dashboard/ai-runner
api:
modules: ai_runs, ai_runs_approvals, ai_runners, ai_runs_settings
tools:
suggestions: How do I start a task with AI? | Can AI work on a task without a machine? | How do I answer an agent's permission request? | Why is my run still queued?
readonly: true
---
# AI Runs
Hands a kanban task to an AI agent: Claude Code or Cursor on one of the workspace's own machines (PromptPilot in runner mode asks OpsAPI for work; OpsAPI never connects to it), or the built-in runner inside OpsAPI. Work happens on a new ai/… branch, never on main.

## Pages
- AI Runs (/dashboard/ai-runner/runs): every run with status, task, runner, folder, branch, tokens and turns; filter by runner or status; updates every 10 s. Managers see overview cards (open runs, queue, runners online, tokens and cost today, last 7 days, average permission wait). Waiting on you lists the requests and approvals you may decide. Open a run for its prompt, live log, conversation, usage, summary, commit, pull request, Cancel and Retry.
- Runners & sources (/dashboard/ai-runner/runners): connections that feed the workspace. A runner runs tasks and reports its sessions; a source (a CI job, another tool) only reports sessions through the open session API and never runs tasks. Filter by kind. Register asks the kind and shows the token once. Per row: Sessions, Reports (what it reports: only these folders, never these folders, only these tools — it can only narrow what the machine's owner allows in runner.json), Access (runners: "Only its owner and AI-run managers", the default, "Everyone who can start runs", or "Selected people and projects"), Pause/Resume, Rotate token, Revoke. Profiles show Available or Unavailable with the reason (e.g. "not logged in") and plan usage.
- Machines (/dashboard/ai-runner/machines): each runner's status, heartbeat, profiles and every session it reported: runs link to their run, others are "Started by hand" (with "Task #N →" once tracked). Filter by runner or Busy only; updates every 15 s.
- AI run settings (/dashboard/ai-runner/settings): default output (pull request, pushed branch, local), PR base and drafts, max run minutes; task automation (when a run starts / succeeds, move its task to a status and optionally a column); the approval policy (who decides requests, project admins deciding too, manager approval for assignee runs, permission and input timeouts); limits (similar-work threshold 10–100%, max open runs per person and workspace, daily token limit — 0 = none — and days run logs are kept; the run, summary and usage stay); Safety (extra denied commands and extra redaction regexes, added to built-in rules that can't be removed); session tracking; routing rules; the prompt template.
- AI Runs platform settings (/dashboard/ai-runner/platform): platform admins only (linked from AI run settings): runner timings, queue and approval timeouts, per-run limits, and the highest values workspaces may set.

## Starting a run
On a task, Start with AI: pick a runner, profile (and model) and repo folder; the prompt is previewed and only managers (manage on AI runs) can edit it. The task's assignee, its project owners/admins or a manager may start, and only on runners whose Access includes them ("You can't use this runner": ask for access under Runners & sources). One open run per task. "A manager must approve this run" means it waits as Needs approval. "Similar work is already open": check the listed runs, then tick Start anyway. Caps or the daily token limit block Start until a run finishes or the next UTC day.

## Built-in runner (no machine)
Every workspace has "OpsAPI built-in", always online and picked when no machine is. It uses the workspace's own AI providers or the platform model (Ollama). Repository "No repository": it plans, comments and adds subtasks. With GitHub connected (Runners & sources → Connect GitHub; a platform admin first sets up the GitHub App) it reads the code, commits to its own branch and opens a pull request. It can't run code or tests, never touches keys, .env or workflow files, and asks no permissions. Pause it or limit its Access like any runner; it has no token.

## Statuses
Needs approval (cancelled after 3 days) → Queued → Claimed → Starting → Running → Succeeded, Failed, Cancelled or Lost (runner stopped reporting). Waiting for permission: the agent asked to do something risky. Needs input: it asked a question. Cancelling: the runner is stopping it.

## Permission requests
Reading and editing files in the folder needs no permission; commands and other risky steps are asked. The run page shows "Needs your decision": Allow (once), Allow for this run (this exact command or file again, not offered for chained or redirected commands), Deny (with a reason). Who decides follows the approval policy; under managers the requester never decides their own run. Too-large requests and unanswered ones (permission timeout) are denied. The runner blocks some commands itself (git push, sudo, secrets, outside the folder, plus the workspace's extra denied commands). Every request, its decision, who decided and when is listed under Permission requests on the run page. The bell tells deciders about new requests, managers about runs needing approval and the requester when the agent asks a question.

## Messages and approvals
The run page's Conversation shows each agent turn with its tokens and people's messages. The requester or a manager can message the agent while the run is open; it gets the message after its current turn. A question ("The agent asks") waits for an answer; without one by the input timeout the run fails. Profiles that can't ask (Cursor) always need a manager's approval to start, and so do runs started by a non-manager when "Runs started by an assignee need a manager's approval first" is on. A manager approves (queues it) or rejects (cancels it, optional reason) from the run page banner or Waiting on you; nobody approves their own run ("Another manager must approve it").

## Usage
The run page totals tokens in and out, cache read and write, the agent's cost estimate and turns. Every turn is also counted on the workspace's AI usage page.

## Sessions started by hand
With Track sessions started by hand on, each busy session someone starts by hand (Claude Code, Cursor, or any source) becomes a task. Routing rules decide first, top to bottom; the first enabled match wins: create a task (project, column, status, priority, assignees, title and description templates with {{first_prompt}}, {{tool_label}}, {{folder}}, {{repo}}, {{branch}}, {{runner}}… and who is told) or ignore it. A session no rule matches goes to the default project. Test a session shows which rule matches and the title it would create, without creating anything. Tunables: ended after (minutes), new tasks per heartbeat, idle statuses, tool names. Titles use the first prompt only when the runner has share_manual_prompts: true; inventory_roots widens which folders it reports.

## Troubleshooting
- Needs approval: another manager must approve it.
- Runner missing from Start with AI: its Access doesn't include you.
- Queued: runner offline, paused or full; check Runners & sources.
- Waiting for permission: someone allowed to decide must answer on the run page or under Waiting on you.
- Refused folder: must be inside the runner's allowed folders, a clean git repo, not used by another run.
- No Start with AI button: plugin off (My Workspace → Plugins) or no create on AI runs.
- Profile unavailable: fix it on the machine (sign Claude in again); its runs wait.
- Offline after rotating the token: put the new token on the machine and restart.
- Rate limited: the plan limit is used up; retry after the reset shown on the runner.
- Built-in runner offers no repositories: connect GitHub (or Refresh repositories).
- A source can't run tasks; no hand-started tasks: check tracking, routing rules (an ignore rule?) and the connection's Reports filter.

## Rules
- The assistant cannot start, cancel, approve or change runs, runners, rules or settings, or decide requests — explain the pages and point to their buttons.
- Never ask for or repeat a runner or source token.
