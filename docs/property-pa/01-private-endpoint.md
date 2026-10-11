# Private AI endpoints (Week 0)

Rule 1: every model call goes to **our own** OpenAI-compatible endpoint. Real client data never goes to
public ChatGPT, Claude or Gemini, and the model is swapped by **config, not code**.

| Setting | Where it is set | Used for | Today (stand-in, fake data only) | Target (PoC) |
|---|---|---|---|---|
| `PA_LLM_BASE_URL` | JobShout: per-org model routing (the org's provider config; env default `OPENAI_BASE_URL`) | All PA agents (Seller PA, Manager PA, capture/extraction, coach, Teach PA) | `http://192.168.1.177:11434/v1` (Ollama on the LAN Mac) | Private UK cloud GPU, OpenAI-compatible (vLLM / TGI / Ollama) |
| `PA_LLM_MODEL` | JobShout: the org's provider config default model (env default `OPENAI_DEFAULT_MODEL`) | as above | `qwen3.8:latest` (27B; tool calling works; 2–6 min per answer on the shared Mac) | Chosen in week 0 on the GPU; must pass the P01–P12 regression set first |
| `PA_STT_URL` | OpsAPI env (`lapis/routes/voice.lua`; falls back to `VOICE_URL`) | Speech-to-text for capture and the mic; text-to-speech for replies | `http://192.168.1.177:8014` (Speaches: faster-whisper-small + Kokoro, British voice `bf_emma`) | The GPU's OpenAI-compatible `/v1/audio/transcriptions` |

## Switching to the UK GPU
1. In JobShout, add or update the org's provider config with the GPU's base URL, key and model, and set the
   fallback order. No code change.
2. In OpsAPI, set `PA_STT_URL` in the env's Helm values (`extraEnv`) or secret.
3. Run the P01–P12 regression suite. Promote only if it passes (rule: run it before any model or provider change).

## Notes
- `https://192.168.1.177:8015` is a Caddy HTTPS front (self-signed, `tls internal`) to Speaches, for browsers using
  Speaches' own playground (the mic needs a secure page). Services call the plain HTTP port 8014.
- Today's stand-in shares one Mac with KubePilot and k3s-worker-08. That is fine for development, but too slow for
  the PoC. A dedicated GPU is a week-0 dependency (target under 10 s per PA turn).
