# dy — AI Gateway

One OpenAI-compatible endpoint in front of **OpenAI, Anthropic, Google Gemini, Azure OpenAI and
AWS Bedrock**. You pick the provider with a *model alias*; the gateway transcodes your request to
that provider's dialect and signs it with that provider's envelope. Your app, your SDK and your
coding agent never learn there are five providers back there.

```
                    POST /v1/chat/completions   ·   /v1/messages   ·   /v1/responses
                                        │  model: "<alias>"
   ┌────────────┬──────────────────────┼──────────────────┬─────────────────┐
"fast"       "claude"               "gemini"           "azure"      "bedrock-claude"
   │        (failover pool)             │                  │                │
 openai   anthropic → bedrock        gemini          azure openai      bedrock (SigV4)
```

```bash
curl -fsSL https://raw.githubusercontent.com/dylankyc/dy/main/quickstart.sh | bash
```

That's it — a gateway on **http://127.0.0.1:8080**, ready for `curl`, the OpenAI/Anthropic SDKs,
**Codex** and **Claude Code**.

---

## Contents

| file | |
|---|---|
| [`quickstart.sh`](./quickstart.sh) | the bootstrapper — installs, starts, tests, tears down |
| [`gateway.config.yml`](./gateway.config.yml) | the routes: providers, aliases, wire ids |
| [`.env.example`](./.env.example) | the credential slots |

The gateway itself ships as `docker.io/dylandylandy/dy` (a Rust binary in a
`debian-slim` image, ~120 MB, non-root, healthchecked).

---

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/dylankyc/dy/main/quickstart.sh | bash
```

The script finds docker (or podman), writes `~/.ai-gateway/{gateway.config.yml,.env}`, starts
`dylandylandy/dy:latest` and waits for `/health`. It is re-runnable and touches nothing else.

```bash
curl -fsSL https://raw.githubusercontent.com/dylankyc/dy/main/quickstart.sh | bash -s -- test claude
curl -fsSL https://raw.githubusercontent.com/dylankyc/dy/main/quickstart.sh | bash -s -- status
```

Prefer not to pipe curl into a shell? Read it first — it's one file:

```bash
curl -fsSLO https://raw.githubusercontent.com/dylankyc/dy/main/quickstart.sh
less quickstart.sh && bash quickstart.sh
```

…or clone this repo and run `./quickstart.sh` (it then keeps state in the clone instead of `~`).

**Commands:** `up` (default) · `down` · `restart` · `logs` · `status` · `models` · `test [alias]`

| variable | default | |
|---|---|---|
| `PORT` | `8080` | host port |
| `BIND` | `127.0.0.1` | **loopback on purpose** — see [Security](#8-security) |
| `AI_GATEWAY_HOME` | `~/.ai-gateway` | where config + credentials live |
| `IMAGE` | `docker.io/dylandylandy/dy:latest` | pin a tag for reproducibility |
| `ENGINE` | auto | force `docker` or `podman` |

---

## 2. Credentials

The config names **environment variables**; it never contains a key. The installer fills
`~/.ai-gateway/.env` from your shell environment, then `~/.secret/*`, then `~/.aws/credentials`.
Every provider is optional — a missing key only disables its aliases.

```ini
OPENAI_API_KEY=sk-…
ANTHROPIC_API_KEY=sk-ant-…
GEMINI_API_KEY=…
AZURE_API_KEY=…
AZURE_ENDPOINT=https://<resource>.openai.azure.com   # required *with* AZURE_API_KEY
AWS_ACCESS_KEY_ID=…                                  # Bedrock; the gateway signs SigV4 itself
AWS_SECRET_ACCESS_KEY=…
AWS_REGION=us-east-1
```

After editing, re-run `quickstart.sh` to recreate the container with the new env.

> Leave `AWS_SESSION_TOKEN` **out** entirely unless you use STS — an *empty* value is signed into
> the request as a blank `x-amz-security-token` and Bedrock answers `403`.

---

## 3. First requests

```bash
# the workhorse surface
curl http://127.0.0.1:8080/v1/chat/completions -H 'content-type: application/json' -d '{
  "model": "fast",
  "messages": [{"role": "user", "content": "Say pong"}]
}'

# same request, different provider — only the alias changed
curl http://127.0.0.1:8080/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"claude","max_tokens":64,"messages":[{"role":"user","content":"Say pong"}]}'

# streaming (SSE)
curl -N http://127.0.0.1:8080/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"gemini","stream":true,"max_tokens":256,"messages":[{"role":"user","content":"count 1 to 5"}]}'

# Anthropic Messages surface
curl http://127.0.0.1:8080/v1/messages -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude","max_tokens":64,"messages":[{"role":"user","content":"Say pong"}]}'

# OpenAI Responses surface
curl http://127.0.0.1:8080/v1/responses -H 'content-type: application/json' \
  -d '{"model":"fast","input":"Say pong"}'

# ops
curl http://127.0.0.1:8080/v1/models      # every alias this gateway serves
curl http://127.0.0.1:8080/health         # → ok
```

Unknown alias → `404 {"error":{"message":"unknown model: …"}}`, answered by the gateway before any
provider is contacted.

---

## 4. Model aliases

An alias is what your client sends; `wire_id` is what the provider is asked for.

| alias | provider | wire id |
|---|---|---|
| `fast` | OpenAI | `gpt-4o-mini` |
| `gpt-4o`, `gpt-4o-mini`, `gpt-5`, `gpt-5.1`, `gpt-5.1-codex`, … | OpenAI | pass-through (alias = wire id) |
| `claude` | Anthropic → **failover** → Bedrock | `claude-haiku-4-5-20251001` / `us.anthropic.claude-haiku-4-5-…` |
| `bedrock-claude` | Bedrock (SigV4) | `us.anthropic.claude-haiku-4-5-…` |
| `gemini` | Google Gemini | `gemini-2.5-flash` |
| `azure` | Azure OpenAI | `gpt-4o-mini` (the *deployment* name) |

Two things worth knowing:

- **`claude` is a pool.** It is registered under both Anthropic and Bedrock, so it resolves to the
  ordered list `[anthropic:claude, bedrock:claude]` — if Anthropic errors, the same request is
  retried against Bedrock, across providers *and* dialects.
- **`max_output_tokens` clamps.** A client sized for Claude (32k) talking to `gpt-4o-mini`
  (16384 cap) would 400; the alias's `max_output_tokens` clamps it instead.

Add your own in `~/.ai-gateway/gateway.config.yml`, then re-run `quickstart.sh`:

```yaml
providers:
  - kind: openai
    name: openai
    api_key_env: OPENAI_API_KEY
    models:
      - alias: my-model          # what clients send
        wire_id: gpt-4o          # what OpenAI is asked for
        max_output_tokens: 16384 # optional clamp
```

`kind` is one of `openai`, `anthropic`, `gemini`, `azure-openai`, `bedrock`, `vertex`. Any
OpenAI-compatible endpoint (vLLM, Ollama, OpenRouter, Groq) fits `kind: openai`.

---

## 5. What works where

Measured against `dylandylandy/dy:v0.1.2`. Rows are the surface your *client* speaks, columns the
provider behind the alias:

| surface | OpenAI (`fast`) | Anthropic (`claude`) | Gemini (`gemini`) |
|---|---|---|---|
| `POST /v1/chat/completions` | ✅ + stream | ✅ + stream | ✅ + stream |
| `POST /v1/messages` (Anthropic) | ✅ + stream | ✅ + stream | ✅ + stream |
| `POST /v1/responses` (OpenAI) | ✅ + stream | ✅ + stream | ❌ *no conversion path* |

The off-diagonal cells are the interesting ones: an Anthropic-shaped client reaching GPT, or Codex
reaching Claude. Streaming is re-emitted in the *client's* dialect, not the provider's.

---

## 6. Codex CLI

`~/.codex/config.toml`:

```toml
model = "fast"                  # any alias from /v1/models
model_provider = "aigw"

[model_providers.aigw]
name = "ai-gateway"
base_url = "http://127.0.0.1:8080/v1"
env_key = "AI_GATEWAY_KEY"      # Codex requires *some* key var; the gateway ignores its value
wire_api = "responses"
```

```bash
export AI_GATEWAY_KEY=dummy
codex                            # or: codex exec "reply with exactly one word: pong"
```

Verified end to end, including **`model = "claude"`** — Codex speaks the Responses API and the
gateway transcodes it to Anthropic Messages.

- `warning: Model metadata for 'fast' not found` is Codex not recognising a non-OpenAI model id.
  Harmless; use a pass-through alias (`gpt-4o`) if it bothers you.
- `Model not found gpt-5.1-codex` (404) comes from **OpenAI**, not the gateway: your key has no
  access to that model. `curl …/v1/models` shows what the gateway offers; your provider account
  decides what it will actually serve.

---

## 7. Claude Code

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8080
export ANTHROPIC_AUTH_TOKEN=dummy      # the gateway doesn't check it; Claude Code needs it set
export ANTHROPIC_MODEL=fast            # ← see the caveat below
export ANTHROPIC_SMALL_FAST_MODEL=fast
claude                                  # or: claude -p "reply with exactly one word: pong"
```

Verified end to end with **transcoded** aliases — `fast`, `gemini`, `azure`. That is Claude Code
driving GPT-4o-mini through the Anthropic Messages surface.

> **Caveat: `ANTHROPIC_MODEL=claude` currently fails** with
> `400 context_management: Extra inputs are not permitted`.
> Claude Code sends the `context_management` field, which needs an `anthropic-beta` header that
> the gateway does not forward (client headers are read for auth only, never proxied upstream).
> On the native Anthropic path the field reaches Anthropic unaccompanied and is rejected; on the
> transcoded paths it is dropped during conversion, which is why those work. Until header
> forwarding lands, point Claude Code at a transcoded alias.

---

## 8. SDKs and other clients

Anything OpenAI-compatible works by changing the base URL; the API key can be any non-empty string.

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="dummy")
client.chat.completions.create(model="claude", max_tokens=64,
                               messages=[{"role": "user", "content": "Say pong"}])
```

```javascript
import OpenAI from "openai";
const client = new OpenAI({ baseURL: "http://127.0.0.1:8080/v1", apiKey: "dummy" });
await client.chat.completions.create({ model: "gemini", messages: [{ role: "user", content: "Say pong" }] });
```

```bash
export OPENAI_BASE_URL=http://127.0.0.1:8080/v1 OPENAI_API_KEY=dummy   # picked up by most tools
```

Anthropic SDKs point at `ANTHROPIC_BASE_URL=http://127.0.0.1:8080`. Editors and frameworks that
accept a custom OpenAI endpoint (Cursor, Continue, LangChain, LlamaIndex, LiteLLM) need the same
two settings.

### Security

**The gateway does not authenticate clients.** The auth hook is a no-op unless a host program
installs one, so anyone who can reach the port can spend your provider credits.

- The installer publishes on `127.0.0.1` for that reason. `BIND=0.0.0.0` is opt-in.
- Exposing it beyond your machine means putting a reverse proxy, an API key or mTLS in front.
- Credentials live only in `~/.ai-gateway/.env` (mode 600) and are passed as container env vars —
  never baked into the image, never in the config file.

---

## 9. Operations

```bash
quickstart.sh status                 # container state, /health, alias list
quickstart.sh logs                   # follow; one line per request from the observer hook
quickstart.sh restart
quickstart.sh down
IMAGE=docker.io/dylandylandy/dy:v0.1.2 quickstart.sh up    # pin a version
```

Routes live in `~/.ai-gateway/gateway.config.yml` (mounted read-only at `/etc/gateway/config.yml`),
credentials in `~/.ai-gateway/.env`. Both are re-read on `up`.

---

## 10. Troubleshooting

| symptom | cause / fix |
|---|---|
| `404 unknown model: X` | the alias isn't in your config — `curl …/v1/models` |
| `404 Model not found Y` (upstream) | the provider won't serve that `wire_id` for your account |
| `502 … builder error` on `azure` | `AZURE_ENDPOINT` missing — set it alongside `AZURE_API_KEY` |
| `403` on `bedrock-*` | usually an **empty** `AWS_SESSION_TOKEN`; remove the line entirely |
| empty content, `finish_reason: length` | reasoning models (`gemini-2.5-flash`) spend the budget on thinking — raise `max_tokens` |
| `no conversion path for surface=…` | that surface × dialect pair isn't implemented (see §5) |
| `400 context_management` | Claude Code on the native `claude` alias — see §7 |
| `statfs … no such file` on start | VM-backed engine can't mount that path — keep `AI_GATEWAY_HOME` under `$HOME` |
| `port is already allocated` | `PORT=18080 quickstart.sh up` |
| everything 000 / connection refused | `quickstart.sh status`, then `quickstart.sh logs` |

---

## What's behind it

A Rust crate stack: a sans-io conversion core (`llm-convert`), a delivery layer
(`llm-transport`), and an orchestration crate that owns routing, load-balanced failover and the
request lifecycle. Cross-cutting policy — auth, rate limiting, observability — is a set of hooks
with no-op defaults, so a host can install its own without forking the gateway.
