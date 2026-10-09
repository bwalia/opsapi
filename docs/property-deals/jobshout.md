# JobShout integration

JobShout API (`server/api/openapi.yaml` on JobShout `origin/master`; gap map §6). OpsAPI side:
`lapis/lib/jobshout-client.lua` (core) and `projects/property-deals/property_deals/ai/runner.lua`,
`property_deals/ai/tick.lua`.

## Link a workspace

JobShout has no API keys. Create a service user in JobShout for the workspace, then:

```http
POST /api/v2/namespace/ai-providers
{ "name": "JobShout", "provider_type": "jobshout", "base_url": "https://int.jobshout.co.uk/api/v1",
  "username": "svc-deals@company.example", "secret": "<service user's password>" }
POST /api/v2/namespace/ai-providers/{id}/test      → { ok, agents }   (signs in, lists agents)
GET  /api/v2/namespace/ai-providers/{id}/agents    → [{ id, name, description }]
PUT  /api/v2/property-deals/ai/agents/legal_chaser
{ "route": "jobshout", "jobshout_provider_uuid": "<link id>", "jobshout_agent_id": "<JobShout agent uuid>",
  "jobshout_project_id": "<optional>", "fallback_to_builtin": true }
```

- **The password** is sealed with AES-256-GCM and never returned.
- **Tokens:** we sign in with `POST /auth/login` and keep the 15-minute access token for 13 minutes in
  the shared cache. On expiry or a 401 we sign in again. Refresh tokens rotate, so we don't store them.

## The flow

| Step | OpsAPI | JobShout |
|---|---|---|
| Start | "Let AI do it" on a task whose agent is routed to JobShout | `POST /tasks/launch { agent_id, project_id?, values: { prompt } }` — `prompt` is a JSON string of the agent key, task title, instructions, the reviewer's note and the minimal records (no contact details) |
| Running | run `provider = jobshout`, `jobshout_run_id` stored | `GET /task-runs/{id}` polled every minute (`jobs/agents_tick.lua`) |
| JobShout wants approval | **one** approval is created here (`jobshout_approval_id`, `action = "jobshout:<tool>"`, payload = the tool input); task → `awaiting_approval` | `GET /approvals` (pending, matched by `execution_id`) |
| A person decides here | approval `executed` (or `rejected`); an approved `send_email` is written to the chase log | `POST /approvals/{id}/decide { decision, reason }` — JobShout runs its tool |
| A person decides in JobShout | mirrored here on the next poll (`decisions[].by = "jobshout"`) | — |
| Run ends | `completed`: tokens + `cost_usd` copied; task done when its approvals were executed. Output without an approval is treated like a built-in draft (it becomes our approval) | `failed`: task back to `todo` with the reason |
| JobShout down | `fallback_to_builtin: true` → the built-in model drafts it (run `fallback_used`); otherwise the run fails with "JobShout unavailable: …" and the task goes back to a person | — |

There is no outbound webhook in JobShout, so we poll. Its WebSocket (`/ws`) only sends hints and is not
used.

## Testing

`spec/mocks.py` implements the endpoints above. `spec/ai_test.py` checks scenario 6:
- launch, and the approval mirrored once;
- one click approves both sides;
- a decision made in JobShout's UI is mirrored here;
- JobShout down, with and without fallback.
