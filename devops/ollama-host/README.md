# Ollama host (hh193)

The platform's own model (the "platform model" / `OLLAMA_URL`, behind `https://ollama.workstation.co.uk`) runs on the
Mac Studio hh193 (`ssh -p 2225`). What runs there and which repo owns it:

| launchd job | Port | What | Owned by |
|---|---|---|---|
| `com.ollama.server` | 11434 | Ollama for OpsAPI (every environment, through the gateway) and the apps that use `acc/ollama-external` | set up by hand |
| `com.ollama.kubepilot` | 11438 | Ollama for kubepilot only (the copy on hh193 and the one in k3s1) | `bwalia/kubepilot` `deploy/macstudio` |
| `com.opsapi.ollama-watchdog` | | restarts `com.ollama.server` when it stops answering | this folder |

**Keep long-running clients off :11434.** OpsAPI's assistant waits on it. Ollama serves only a few requests at a
time (`OLLAMA_NUM_PARALLEL`), so a client sending 1–3 minute requests non-stop leaves OpsAPI's `qwen3.8` without a
turn, and every environment's assistant times out. That is why kubepilot has its own instance; give any other heavy
client one too, the same way.

## Watchdog

Ollama 0.34's scheduler can wedge: `/api/version` answers but no generation ever starts, until a restart. Every 2
minutes the watchdog asks `qwen3.8` for one token (keeping it loaded). After 3 checks in a row without an answer
(about 6 minutes) it runs `launchctl kickstart -k gui/<uid>/com.ollama.server`, then waits at least 10 minutes before
it would restart again. It leaves a stopped server to launchd's `KeepAlive`.

```bash
bash devops/ollama-host/install.sh        # on hh193: install or update (safe to repeat)
tail ~/Library/Logs/ollama/watchdog.log   # what it saw and did
bash devops/ollama-host/test-watchdog.sh  # anywhere on macOS: checks the logic against a fake Ollama
```

Settings (environment of the job, rarely needed): `OLLAMA_WATCHDOG_MODEL` (default `qwen3.8:latest`),
`OLLAMA_WATCHDOG_FAILS` (3), `OLLAMA_WATCHDOG_COOLDOWN` (600 s), `OLLAMA_WATCHDOG_URL`, `OLLAMA_WATCHDOG_LABEL`.
