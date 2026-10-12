---
title: AI Runs
pages: /dashboard/ai-runner
api:
modules: ai_runs, ai_runs_approvals, ai_runners, ai_runs_settings
tools:
suggestions: How do I start a task with AI? | How do I connect a machine? | Why is my run still queued?
readonly: true
---
# AI Runs
Hands a kanban task to an AI coding agent (Claude Code, Cursor, Ollama) running on one of the workspace's own machines. The machine runs PromptPilot in runner mode: it asks OpsAPI for work, so OpsAPI never connects to the machine. The agent works in a repo folder on that machine, on a new ai/… branch, never on main.

## Pages
- AI Runs (/dashboard/ai-runner/runs): every run, newest first, with status, task, runner, folder and branch. Filter by runner or status. Updates every 10 seconds. Open a run to see its prompt, live log, summary, commit and pull request, and to Cancel or Retry it.
- Runners (/dashboard/ai-runner/runners): Register runner gives a token once — copy it into the machine's runner config. Pause, Resume, Rotate token and Revoke each runner. Sessions shows what the machine last reported, including sessions started by hand, so you can see what is already running before starting more.
- AI run settings (/dashboard/ai-runner/settings): default output (pull request, pushed branch or local only), pull request base branch and drafts, max run minutes, moving the task to In progress / Review, who decides permission requests, whether runs started by an assignee need a manager, and the prompt template every run starts from.

## Starting a run
On a task page, Start with AI: choose a runner, an agent profile (and model), and the repo folder on that machine. The prompt is shown before you start; a manager can edit it. Only the task's assignee, an owner or admin of its project, or someone with manage on AI runs can start a run. A task has at most one open run.

## Statuses
queued (waiting for its runner) → claimed → starting → running → succeeded, failed, cancelled or lost. cancelling means a cancel was asked for and the runner is stopping the agent. lost means the runner stopped reporting.

## Troubleshooting
- Stuck in queued: the runner is offline or paused, or busy with as many runs as it allows. Check Runners: it should be online.
- Refused folder: the folder must be inside the runner's allowed folders, be a git repo, have no uncommitted changes, and not be used by another run.
- No Start with AI button: the AI Runs plugin is off for this workspace (My Workspace → Plugins) or your role lacks create on AI runs.
- Runner shows offline after a token rotation: put the new token in the machine's config and restart the runner.

## Rules
- The assistant cannot start, cancel or change runs or runners — explain the pages and guide the user to their buttons.
- Never ask for or repeat a runner token.
