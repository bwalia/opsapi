# AI providers, platform model and voice

How OpsAPI talks to models, and the settings that control it. Code:
`lapis/lib/agent/llm.lua` (every model call), `lapis/lib/ai-providers.lua`
(per-workspace providers), `lapis/routes/voice.lua` (speech).

## The platform model

One setting for every built-in AI feature (page assistant, chat agent, tax
classification, bookkeeping, statement extraction): `AI_PROVIDER`
(`ollama` | `anthropic` | `openai`), `AI_MODEL`, `AI_API_KEY`, `AI_BASE_URL`,
falling back to `OLLAMA_URL` / `OLLAMA_MODEL` / `OLLAMA_API_KEY` and friends.
When it fails, the call is retried once on `AI_FALLBACK_PROVIDER` /
`AI_FALLBACK_MODEL` (Ollama by default, `none` turns it off); a provider that
is down is skipped for 60 s (circuit breaker).

## Per-workspace providers

`/api/v2/namespace/ai-providers` (`namespace.read` / `namespace.update`): a
workspace brings its own cloud key (Anthropic, OpenAI, Gemini, Mistral, Azure
OpenAI), a local OpenAI-compatible server (Ollama, LM Studio, vLLM, …), a
JobShout link, or opts into the platform model.

- Keys are sealed with AES-256-GCM (`helper/secret-box.lua`, needs
  `OPENSSL_SECRET_KEY`) and never returned; the API shows `has_secret` and a
  hint. Without `OPENSSL_SECRET_KEY` a key can't be saved (422) and a stored
  one can't be used (the provider is reported unavailable, never used unsealed).
- A workspace provider **never falls back to the platform's model**: its data
  only goes where the workspace said. Its circuit breaker is its own, so one
  workspace's bad key can't mark another's provider down.
- If the workspace picked a provider for the assistant and it can't be used,
  the assistant answers 503 instead of silently using the platform model.
- Local servers (`ollama`, `openai_compatible`) are streamed (OpenAI SSE with
  usage), so proxies that cut silent connections don't drop slow answers.
- Errors shown to the workspace (`/test`, `last_error`, JobShout, plugin
  attempts) are short reasons — "Authentication failed (401) — check the API
  key", "Not found (404)", "Rate limited (429)", "Timed out", "Couldn't
  connect" — never the server's own text. Details go to the server log.

### The platform model for workspaces

`provider_type = "platform"` shares the deployment's self-hosted (Ollama)
model. Workspaces can only choose models in `AI_PLATFORM_MODELS`
(comma-separated; default: the platform's own model), so nobody can make the
shared server load an arbitrary large model.

## Private hosts (SSRF)

Workspace URLs must resolve to public addresses, and every call connects to
the address that was checked (no DNS rebinding between check and connect).

- `OPSAPI_AI_PRIVATE_HOSTS=ollama.office.lan:11434,lmstudio.lan` — private
  model servers workspaces may use (`host` = any port, `host:port` = that
  port). The preferred way.
- `OPSAPI_AI_ALLOW_PRIVATE=true` — any private address. **Development only**:
  every `namespace.update` holder could reach databases, Redis, the cluster
  API. Logged as a warning at startup.
- Link-local addresses (169.254.0.0/16: cloud metadata) are refused always,
  with either setting. IPv6 targets aren't used.

## TLS

Model servers' certificates are verified (nginx `lua_ssl_trusted_certificate`
points at the system CA bundle). `AI_TLS_VERIFY=false` skips the check for
local development against a self-signed endpoint; plain `http://` URLs are
unaffected. JobShout has its own `JOBSHOUT_TLS_VERIFY`.

## Time limits

Each model call has a **total** budget — a streamed answer and the fallback
included (a socket timeout alone restarts on every streamed chunk). With a
fallback, the main provider gets two thirds of it.

| Setting | Default | Used for |
|---|---|---|
| `AI_REQUEST_TIMEOUT_MS` | 120000 | calls made while serving a request (someone is waiting) |
| `AI_TIMEOUT_MS` | 300000 | background work: timers, plugin jobs, assistant runs |
| caller's `timeout_ms` | — | wins when given (tax 60 s, bookkeeping 30 s, provider test 30 s) |

An assistant run (all its model calls and tools) gets 15 minutes in total;
the conversation reports a run as interrupted only after 30 minutes, so a
second run can't start while the first is still working.

## Voice

`VOICE_URL` (or `PA_STT_URL`, which wins) points at our own OpenAI-compatible
speech server (e.g. Speaches); `VOICE_API_KEY` optional, plus
`VOICE_STT_MODEL`, `VOICE_TTS_MODEL`, `VOICE_TTS_VOICE`, `VOICE_LANGUAGE`.
It is operator config, so a LAN address is fine (no `OPSAPI_AI_*` setting
needed). The routes need a workspace (`X-Namespace-Id`) and are rate-limited
per user: 20 transcriptions and 30 spoken replies a minute; audio (max 10 MB)
is streamed on to the server, not copied in memory.

## Metering

Every model call is one `ai_usage` row: who, workspace, feature, provider,
model, tokens in/out (cached input separately), latency, outcome. Workspace
providers also report a cost from their per-million-token prices.
`AI_USER_DAILY_TOKEN_LIMIT` (optional) caps one user's tokens per UTC day
across every feature. Reports: Activity → AI usage.

Every variable read by Lua must be declared `env NAME;` in all four nginx
confs (`lapis/nginx*.conf`) and documented in `lapis/.sample.env`.
