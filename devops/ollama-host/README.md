# Ollama host (hh193)

The platform's own model (the "platform model" / `OLLAMA_URL`) runs on the Mac Studio hh193 (`ssh -p 2225`). OpsAPI
has its **own** Ollama there, separate from the one the other products share. What runs there and which repo owns it:

| launchd job | Port | What | Owned by |
|---|---|---|---|
| `com.opsapi.ollama` | 11439 | Ollama for OpsAPI only | this folder |
| `com.opsapi.ollama-watchdog` | | keeps `qwen3.8` loaded on :11439 and restarts `com.opsapi.ollama` when it stops answering | this folder |
| `com.ollama.server` | 11434 | shared Ollama: the other products, `acc/ollama-external`, and the gateway `ollama.workstation.co.uk` | set up by hand |
| `com.ollama.kubepilot` | 11438 | Ollama for kubepilot only | `bwalia/kubepilot` `deploy/macstudio` |

**Why OpsAPI has its own.** Ollama serves only a few requests at a time (`OLLAMA_NUM_PARALLEL`) from one queue, and
its scheduler can wedge for every model at once. On the shared :11434, other products sending 1–3 minute requests
non-stop left OpsAPI's `qwen3.8` without a turn, or wedged it, and every environment's assistant timed out. A
separate `ollama serve` has its own queue, slots and scheduler. It reads the same model files (`~/.ollama/models`),
so nothing is downloaded twice; it does share the machine's GPU and memory.

```bash
bash devops/ollama-host/install.sh        # on hh193: install or update both jobs (safe to repeat)
curl -s 127.0.0.1:11439/api/ps            # what OpsAPI's Ollama has loaded
tail ~/Library/Logs/ollama/opsapi.err.log # its log
tail ~/Library/Logs/ollama/watchdog.log   # what the watchdog saw and did
bash devops/ollama-host/test-watchdog.sh  # anywhere on macOS: checks the watchdog against a fake Ollama
```

To use a model OpsAPI doesn't have yet: `OLLAMA_HOST=127.0.0.1:11439 /opt/homebrew/bin/ollama pull <model>` (the
files land in the shared folder, so the other instances can use them too).

## Watchdog

Ollama 0.34's scheduler can wedge: `/api/version` answers but no generation ever starts, until a restart. Every 2
minutes the watchdog asks `qwen3.8` for one token on :11439 (keeping it loaded). After 3 checks in a row without an
answer (about 6 minutes) it runs `launchctl kickstart -k gui/<uid>/com.opsapi.ollama`, then waits at least 10 minutes
before it would restart again. It leaves a stopped server to launchd's `KeepAlive`.

Settings (environment of the job, rarely needed): `OLLAMA_WATCHDOG_MODEL` (default `qwen3.8:latest`),
`OLLAMA_WATCHDOG_FAILS` (3), `OLLAMA_WATCHDOG_COOLDOWN` (600 s), `OLLAMA_WATCHDOG_URL` (`http://127.0.0.1:11439`),
`OLLAMA_WATCHDOG_LABEL` (`com.opsapi.ollama`).
