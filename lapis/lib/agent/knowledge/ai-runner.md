---
title: AI Runs
pages: /dashboard/ai-runner
api:
modules: ai_runs, ai_runs_approvals, ai_runners, ai_runs_settings
tools:
suggestions: How do I start a task with AI? | How do I answer an agent's permission request? | Why is my run still queued?
readonly: true
---
# AI Runs
Hands a kanban task to an AI coding agent (Claude Code, Cursor, Ollama) running on one of the workspace's own machines. The machine runs PromptPilot in runner mode: it asks OpsAPI for work, so OpsAPI never connects to the machine. The agent works in a repo folder on that machine, on a new ai/… branch, never on main.

## Pages
- AI Runs (/dashboard/ai-runner/runs): every run, newest first, with status, task, runner, folder and branch, tokens and turns. Filter by runner or status. Updates every 10 seconds. At the top, Waiting on you lists the permission requests and start approvals you may decide, with quick Allow / Deny and Approve / Reject buttons and a link to each run. Open a run to see its prompt, live log, conversation, usage, summary, commit and pull request, and to Cancel or Retry it.
- Runners (/dashboard/ai-runner/runners): Register runner gives a token once — copy it into the machine's runner config. Pause, Resume, Rotate token and Revoke each runner. Each profile shows how much of its plan limit is used and when it resets (for example "53% of the 7-day limit used"). Sessions shows what the machine last reported, including sessions started by hand, so you can see what is already running before starting more.
- AI run settings (/dashboard/ai-runner/settings): default output (pull request, pushed branch or local only), pull request base branch and drafts, max run minutes, moving the task to In progress / Review, the approval policy (who decides permission requests, whether runs started by an assignee need a manager, the permission timeout and the input timeout, in minutes), and the prompt template every run starts from.

## Starting a run
On a task page, Start with AI: choose a runner, an agent profile (and model), and the repo folder on that machine. The prompt is shown before you start; a manager can edit it. Only the task's assignee, an owner or admin of its project, or someone with manage on AI runs can start a run. A task has at most one open run. When the dialog says "A manager must approve this run before it starts", the run is created as Needs approval and waits for a manager.

## Statuses
- Needs approval (pending_approval): waiting for a manager to approve the start; no runner picks it up. Cancelled after 3 days without a decision.
- Queued (waiting for its runner) → Claimed → Starting → Running → Succeeded, Failed, Cancelled or Lost.
- Waiting for permission (waiting_permission): the agent asked to do something risky, such as running a command, and waits for a decision.
- Needs input (needs_input): the agent asked a question and waits for an answer.
- Cancelling: a cancel was asked for and the runner is stopping the agent. Lost: the runner stopped reporting.

## Deciding permission requests
Reading and editing files in the run's folder needs no permission. Running commands and anything else risky is asked first. The run page shows "Needs your decision" with the tool, the command or file, the path and the agent's description:
- Allow: this once.
- Allow for this run: also allows the same kind of request (for a command, its first two words) later in this run without asking.
- Deny: the agent is told no, with your reason if you give one, and carries on.
Who may decide depends on the approval policy in AI run settings: managers (manage on AI runs or AI run approvals, or an owner or admin of the task's project), the person who started the run, or either. Others see "Waiting for a decision". A request nobody answers within the permission timeout is denied. Some commands (git push, sudo, reading secrets, anything outside the folder) are blocked by the runner itself and never reach you. Every request and its decision, who decided and when, is listed under Permission requests on the run page.

## Messaging the agent
The run page's Conversation shows each agent turn with its tokens and every message people sent. The person who started the run, or a manager, can type in the message box while the run is open: a follow-up is delivered after the agent's current turn. When the agent asks a question it is highlighted as "The agent asks" and the run waits for your answer; without one within the input timeout the run fails.

## Approvals
Runs of profiles that can't ask for permission (such as Cursor) always need a manager's approval to start; with "Runs started by an assignee need a manager's approval first" switched on, so do runs started by someone who is not a manager. A manager approves or rejects (with an optional reason) from the banner on the run page or from Waiting on you. Approve queues the run; Reject cancels it.

## Usage
The run page totals tokens in and out, cache read and write, the agent's cost estimate and the number of turns. Every turn is also counted on the workspace's AI usage page.

## Troubleshooting
- Stuck in Needs approval: a manager has to approve it.
- Stuck in queued: the runner is offline or paused, or busy with as many runs as it allows. Check Runners: it should be online.
- Stuck in Waiting for permission: someone allowed to decide has to answer on the run page or under Waiting on you.
- Refused folder: the folder must be inside the runner's allowed folders, be a git repo, have no uncommitted changes, and not be used by another run.
- No Start with AI button: the AI Runs plugin is off for this workspace (My Workspace → Plugins) or your role lacks create on AI runs.
- Runner shows offline after a token rotation: put the new token in the machine's config and restart the runner.
- A run failed as rate limited: the agent's plan limit is used up; Runners shows when it resets. Retry after that.

## Rules
- The assistant cannot start, cancel, approve or change runs or runners, and cannot decide permission requests — explain the pages and guide the user to their buttons.
- Never ask for or repeat a runner token.
