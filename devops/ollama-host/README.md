# Ollama host (hh193)

The platform's own model (the "platform model" / `OLLAMA_URL`) runs on the Mac Studio hh193 (`ssh -p 2225`). OpsAPI
has its **own** Ollama there, separate from the one the other products share. What runs there and which repo owns it:

| launchd job | Port | What | Owned by |
|---|---|---|---|
| `com.opsapi.ollama` | 11439 | Ollama for OpsAPI only (copy A) | this folder |
| `com.opsapi.ollama-b` | 11440 | Ollama for OpsAPI only (copy B) | this folder |
| `com.opsapi.ollama-watchdog` | | keeps `qwen3.8` loaded on both copies and restarts a copy that stops answering | this folder |
| `com.ollama.server` | 11434 | shared Ollama: the other products, `acc/ollama-external`, and the gateway `ollama.workstation.co.uk` | set up by hand |
| `com.ollama.kubepilot` | 11438 | Ollama for kubepilot only | `bwalia/kubepilot` `deploy/macstudio` |

**Why OpsAPI has its own.** Ollama serves only a few requests at a time (`OLLAMA_NUM_PARALLEL`) from one queue, and
its scheduler can wedge for every model at once. On the shared :11434, other products sending 1–3 minute requests
non-stop left OpsAPI's `qwen3.8` without a turn, or wedged it, and every environment's assistant timed out. A
separate `ollama serve` has its own queue, slots and scheduler. It reads the same model files (`~/.ollama/models`),
so nothing is downloaded twice; it does share the machine's GPU and memory.

**Why two copies, and not more.** The gateway sends OpsAPI's requests to copy A, B, or the shared :11434 as a last
resort (wslproxy `failover`, see below), so one copy freezing doesn't stop the assistant. Each copy keeps `qwen3.8`
(~17.5 GB) in memory, and all of them share one GPU: more copies add no speed and would push the machine into swap,
which stalls every product. For more than this, add a second machine as another backend.

**How OpsAPI reaches them.** `OLLAMA_URL=https://ollama.workstation.co.uk/opsapi`. The edge rule for `/opsapi` checks
the same signed key as the rest of `ollama.workstation.co.uk`, drops the prefix, and uses wslproxy's `failover` mode
over the home router's forwards: `vpnhh.workstation.co.uk:31439` → :11439 (A), `:31440` → :11440 (B), then `:31434` →
:11434 (shared). A backend that errors or times out is retried on the next one at once, and skipped for 30 s after
3 failures in a row.

```bash
bash devops/ollama-host/install.sh        # on hh193: install or update both copies + watchdog (safe to repeat)
curl -s 127.0.0.1:11439/api/ps            # what copy A has loaded (copy B: :11440)
tail ~/Library/Logs/ollama/opsapi.err.log # copy A's log (copy B: opsapi-b.err.log)
tail ~/Library/Logs/ollama/watchdog.log   # what the watchdog saw and did
bash devops/ollama-host/test-watchdog.sh  # anywhere on macOS: checks the watchdog against a fake Ollama
```

To use a model OpsAPI doesn't have yet: `OLLAMA_HOST=127.0.0.1:11439 /opt/homebrew/bin/ollama pull <model>` (the
files land in the shared folder, so the other instances can use them too).

## Watchdog

Ollama 0.34's scheduler can wedge: `/api/version` answers but no generation ever starts, until a restart. Every 2
minutes the watchdog asks `qwen3.8` for one token on each copy, at the same time (keeping it loaded). After 3 checks
in a row without an answer from a copy (about 6 minutes) it restarts that copy only (`launchctl kickstart -k`), then
waits at least 10 minutes before it would restart it again. It leaves a stopped server to launchd's `KeepAlive`.

Settings (environment of the job, rarely needed): `OLLAMA_WATCHDOG_MODEL` (default `qwen3.8:latest`),
`OLLAMA_WATCHDOG_FAILS` (3), `OLLAMA_WATCHDOG_COOLDOWN` (600 s), `OLLAMA_WATCHDOG_TARGETS` (`url=label` pairs,
default both copies).
