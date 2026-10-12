---
title: AI models
pages: /dashboard/namespace/ai
api: /api/v2/namespace/ai-providers
modules: namespace
tools:
suggestions: Which AI models can this workspace use? | Why does the OpenAI test fail? | Use the platform model for the assistant
readonly: false
---
# AI models
The AI models this workspace's features may use: the platform's own self-hosted model, or the workspace's own provider (Anthropic, OpenAI, Gemini, Azure OpenAI, Mistral, Ollama, or any OpenAI-compatible server). Plugins such as Property Deals pick from this list; one provider can also be marked to run the AI assistant.

## Using the page
- **Add provider** opens a form: Name, Provider type, Base URL (only for self-hosted / Azure / OpenAI-compatible), Default model, API key (password field; saved encrypted, never shown again — the list shows only a hint like "…a1b2"), Enabled.
- Each row: **Test connection**, **Edit**, **Delete**, and the **Assistant** switch. At most one provider runs the assistant: switching it on for one switches it off for the others.
- Readers (`namespace` read) see the list; adding, editing, testing and deleting need `namespace` update.

## Rules
- Never ask for, repeat or set an API key through chat — the user types it into the page.
- A workspace's own provider never falls back to the platform model: if it fails, the feature reports the provider as unavailable.
- The platform model is only offered with the models the platform allows; other model names are refused (422).
- Self-hosted URLs must be public addresses unless the platform administrator allowed that host.
- Test results are short reasons (e.g. "Authentication failed (401) — check the API key", "Model not found (404)", "Timed out", "Couldn't connect").

## API
- `GET /api/v2/namespace/ai-providers` — list (uuid, name, provider_type, base_url, default_model, models, has_secret, secret_hint, is_local, enabled, options, last_tested_at, last_error)
- `POST /api/v2/namespace/ai-providers` — create { name, provider_type, base_url?, default_model?, models?, username?, options?, enabled? } (the key is entered in the page)
- `GET /api/v2/namespace/ai-providers/:id` — one provider
- `PUT /api/v2/namespace/ai-providers/:id` — partial update; `options` replaces the whole object, so send the existing options with the change (e.g. `{ ...options, assistant: true }`)
- `DELETE /api/v2/namespace/ai-providers/:id` — remove
- `POST /api/v2/namespace/ai-providers/:id/test` — test the connection
- `GET /api/v2/namespace/ai-providers/:id/agents` — JobShout agents (JobShout providers only)
