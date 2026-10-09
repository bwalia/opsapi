# Local LLMs

Any OpenAI-compatible server works as a workspace AI provider.

| Server | base_url | provider_type |
|---|---|---|
| Ollama | `http://<host>:11434/v1` | `ollama` (or `openai_compatible`) |
| LM Studio | `http://<host>:1234/v1` | `openai_compatible` |
| vLLM | `http://<host>:8000/v1` | `openai_compatible` |
| llama.cpp server | `http://<host>:8080/v1` | `openai_compatible` |
| LocalAI | `http://<host>:8080/v1` | `openai_compatible` |

```http
POST /api/v2/namespace/ai-providers
{ "name": "Office Ollama", "provider_type": "ollama", "base_url": "http://10.0.0.5:11434/v1",
  "default_model": "qwen3:8b", "is_local": true }
POST /api/v2/namespace/ai-providers/{id}/test
PUT  /api/v2/property-deals/ai/routes/draft     { "chain": [{ "provider_uuid": "<id>" }], "local_only": true }
```

- **Private addresses:** a model server on a private network (10.x, 192.168.x, `localhost`, `*.local`)
  needs `OPSAPI_AI_ALLOW_PRIVATE=true` on the OpsAPI deployment. Without it, provider URLs must be
  public `https://` hosts. That stops a workspace pointing the server at internal services (SSRF).
  Self-hosted and office installs set it; shared SaaS deployments shouldn't.
- **`is_local: true`** marks a provider as on-premises. A route or agent with `local_only` (e.g. for ID
  documents) only uses those.
- **Choosing a model:** use one that follows JSON instructions. Tool calling helps but isn't needed: the
  agents fall back to plain JSON with the records in the prompt. For 8 GB machines, a 7–8B instruct
  model (Qwen3 8B, Llama 3.1 8B) is enough for chase emails and digests.
- **Costs:** set `input_cost_per_mtok` / `output_cost_per_mtok` to 0 for a local model. The run log
  still records tokens and latency.
- **Fallback:** list a local model after a cloud one in a route's `chain`. When the cloud API is down or
  over quota, the next run step moves on to the local model and the run stays on it.

The tests use exactly this path: `spec/mocks.py` plays an OpenAI-compatible local model at
`http://pd-mock:8080/v1`, behind a cloud provider that is down.
