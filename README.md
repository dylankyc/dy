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

That's it — a gateway on **http://127.0.0.1:8000**, ready for `curl`, the OpenAI/Anthropic SDKs,
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
| `PORT` | `8000` | host port |
| `BIND` | `127.0.0.1` | **loopback on purpose** — see [Security](#security) |
| `AI_GATEWAY_HOME` | `~/.ai-gateway` | where config + credentials live |
| `LOG_LEVEL` | `info` | `error`\|`warn`\|`info`\|`debug`\|`trace` (see [Logging](#9-logging)) |
| `IMAGE` | `docker.io/dylandylandy/dy:latest` | pin a tag, or use `:latest-distroless` |
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
curl http://127.0.0.1:8000/v1/chat/completions -H 'content-type: application/json' -d '{
  "model": "fast",
  "messages": [{"role": "user", "content": "Say pong"}]
}'

# same request, different provider — only the alias changed
curl http://127.0.0.1:8000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"claude","max_tokens":64,"messages":[{"role":"user","content":"Say pong"}]}'

# streaming (SSE)
curl -N http://127.0.0.1:8000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"gemini","stream":true,"max_tokens":256,"messages":[{"role":"user","content":"count 1 to 5"}]}'

# Anthropic Messages surface
curl http://127.0.0.1:8000/v1/messages -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude","max_tokens":64,"messages":[{"role":"user","content":"Say pong"}]}'

# OpenAI Responses surface
curl http://127.0.0.1:8000/v1/responses -H 'content-type: application/json' \
  -d '{"model":"fast","input":"Say pong"}'

# ops
curl http://127.0.0.1:8000/v1/models      # every alias this gateway serves
curl http://127.0.0.1:8000/health         # → ok
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

- **`claude` is a pool.** It is registered under both Anthropic and Bedrock, so it resolves to
  `[anthropic:claude, bedrock:claude]` — one alias, two hosts, two dialects.

  ```yaml
  server:
    load_balance: round-robin   # or: failover (default)
  ```

  `failover` is a strict primary/secondary: the first target serves everything while it is
  healthy, and the rest exist for when it isn't. `round-robin` rotates the starting point per
  request, so traffic spreads across every target of the alias. Failover is the default because
  providers differ in price, quota and latency — spreading traffic across them is your call, not
  the gateway's. **Either way** a retryable error still walks the remaining targets: rotation
  changes where the walk starts, never that it happens.
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

For Bedrock, `wire_id` takes either a plain model id or a full **ARN** — inference profiles,
provisioned throughput, custom models:

```yaml
- alias: opus
  wire_id: "arn:aws:bedrock:us-east-1::inference-profile/us.anthropic.claude-opus-4-8"
```

> Newer Claude models drop parameters older ones accept. `claude-opus-4-8`, for instance, answers
> ``400 `temperature` is deprecated for this model`` — so an OpenAI-style client that always sends
> `temperature` will fail against it while working fine against `claude-haiku-4-5`. That is the
> provider's rule, not the gateway's; pick a model your clients' parameters suit.

---

## 5. What works where

Measured against `dylandylandy/dy:v0.1.11`. Rows are the surface your *client* speaks, columns the
provider behind the alias:

| surface | OpenAI (`fast`) | Anthropic (`claude`) | Bedrock (`bedrock-claude`) | Gemini (`gemini`) |
|---|---|---|---|---|
| `POST /v1/chat/completions` | ✅ + stream | ✅ + stream | ✅ + stream | ✅ + stream |
| `POST /v1/messages` (Anthropic) | ✅ + stream | ✅ + stream | ✅ + stream | ✅ + stream |
| `POST /v1/responses` (OpenAI) | ✅ + stream | ✅ + stream | ✅ + stream | ❌ *no conversion path* |

The off-diagonal cells are the interesting ones: an Anthropic-shaped client reaching GPT, or Codex
reaching Claude. Streaming is re-emitted in the *client's* dialect, not the provider's — Bedrock
answers in binary AWS eventstream frames, and the gateway decodes and re-emits them as whatever
SSE dialect the client is speaking.

Because `claude` is a **pool** (`anthropic` → `bedrock`), both legs must support the surface you
call or the failover half is dead. All three surfaces now cover both hosts.

> Failover triggers on *retryable* upstream errors — timeouts, network failures, `429` and `5xx`.
> An authentication error (`401` on a bad key) is **terminal by design**: it is a configuration
> bug you want surfaced, not masked by quietly spending on the next provider.

---

## 6. Codex CLI

`~/.codex/config.toml`:

```toml
model = "fast"                  # any alias from /v1/models
model_provider = "aigw"

[model_providers.aigw]
name = "ai-gateway"
base_url = "http://127.0.0.1:8000/v1"   # ← must match the port the installer printed
env_key = "AI_GATEWAY_KEY"      # Codex requires *some* key var; the gateway ignores its value
wire_api = "responses"          # omit (or "chat") to use /v1/chat/completions instead
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
- A 404 that doesn't look like either of those usually means `base_url` points somewhere else
  entirely — `:8000` is a popular port, and a local nginx or Kong will happily answer it with its
  own 404. `curl -i http://localhost:<port>/health` should return a bare `ok`; anything carrying a
  `Server:` header is not this gateway. (The installer refuses to start on an occupied port and
  names the occupant, so this only bites when your client and the gateway disagree about the port.)

---

## 7. Claude Code

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8000
export ANTHROPIC_AUTH_TOKEN=test           # the gateway doesn't check it; Claude Code needs it set
export ANTHROPIC_API_KEY=test
export ANTHROPIC_MODEL=claude              # any alias — native Anthropic *or* Bedrock
export ANTHROPIC_DEFAULT_SONNET_MODEL=claude
export ANTHROPIC_SMALL_FAST_MODEL=claude
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1    # see the caveat below
claude                                      # or: claude -p "reply with exactly one word: pong"
```

Verified end to end against **every** alias kind: `fast` (transcoded to OpenAI), `claude` (native
Anthropic), and `bedrock-claude` (Bedrock via SigV4). A `claude` pool ordered bedrock-first serves
Claude Code from Bedrock; ordered anthropic-first, from Anthropic — same alias, same session.

Claude Code sends fields that older host schemas reject, and the gateway normalizes them rather
than forwarding a 400:

| what Claude Code sends | host | gateway does |
|---|---|---|
| `thinking: {type: "adaptive"}` | Bedrock rejects the tag; Anthropic rejects it per-model | dropped (recorded as a downgrade) — `enabled`/`disabled` pass through untouched |
| `output_config`, `mcp_servers`, `service_tier`, `context_management` | Bedrock: `"…: Extra inputs are not permitted"` | filtered to the fields the invoke schema accepts |
| a `system`-role entry inside `messages[]` | **every** host: `Unexpected role "system"` | hoisted into the top-level `system`, merged with one already there; content blocks and their `cache_control` survive |
| `output_config: {effort: "xhigh"}` | Anthropic: `This model does not support the effort parameter` | `effort` stripped (top level, inside `thinking`, and inside `output_config`); the rest of `output_config` is kept |
| `tools: [{type: "web_search_20250305"}]` | Bedrock/Vertex: `tool type … is not supported for this model` | server-side tools are filtered out; your custom tools go through untouched |

> **Caveat:** leave `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` set. Without it Claude Code sends
> beta-gated fields with an `anthropic-beta` header, and the gateway does not forward client
> headers upstream (they are read for auth only), so **native Anthropic** answers
> `400 context_management: Extra inputs are not permitted`. Bedrock is unaffected — its allowlist
> drops those fields — so this only bites the native leg.

---

## 8. SDKs and other clients

Anything OpenAI-compatible works by changing the base URL; the API key can be any non-empty string.

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:8000/v1", api_key="dummy")
client.chat.completions.create(model="claude", max_tokens=64,
                               messages=[{"role": "user", "content": "Say pong"}])
```

```javascript
import OpenAI from "openai";
const client = new OpenAI({ baseURL: "http://127.0.0.1:8000/v1", apiKey: "dummy" });
await client.chat.completions.create({ model: "gemini", messages: [{ role: "user", content: "Say pong" }] });
```

```bash
export OPENAI_BASE_URL=http://127.0.0.1:8000/v1 OPENAI_API_KEY=dummy   # picked up by most tools
```

Anthropic SDKs point at `ANTHROPIC_BASE_URL=http://127.0.0.1:8000`. Editors and frameworks that
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

## 9. Logging

On startup the gateway logs **every route it serves** — alias, failover chain, the wire id each
one resolves to, and the dialect/envelope pairing. `quickstart.sh logs` answers "what does this
thing actually serve?" without sending a request:

```
INFO llm-gateway listening on 0.0.0.0:8000 (log level: info)
INFO surfaces:
INFO   POST /v1/chat/completions   POST /v1/messages   POST /v1/responses
INFO   GET  /v1/models             GET  /health
INFO routes: 12 aliases
INFO   fast               → openai:fast              gpt-4o-mini [OpenAi/OpenAiNative] max_output_tokens=16384
INFO   gpt-4o             → openai:gpt-4o            gpt-4o [OpenAi/OpenAiNative] max_output_tokens=16384
INFO   claude             → anthropic:claude         claude-haiku-4-5-20251001 [Anthropic/AnthropicNative]
INFO                      ↳ bedrock:claude           us.anthropic.claude-haiku-4-5-… [Anthropic/Bedrock] (failover)
INFO   gemini             → gemini:gemini            gemini-2.5-flash [Gemini/Gemini]
INFO   azure              → azure:azure              gpt-4o-mini [OpenAi/AzureOpenAi] max_output_tokens=16384
```

Then one line per request: `[ok] principal=anonymous model=fast provider=openai latency=1.2s`.

Pick the verbosity — first source that is set wins:

| source | example | |
|---|---|---|
| `RUST_LOG` | `RUST_LOG=llm_gateway=debug,warn` | full filter syntax, per-target |
| `LOG_LEVEL` | `LOG_LEVEL=debug` | the simple knob |
| `server.log_level` in `gateway.config.yml` | `log_level: info` | a deployment's default |
| — | `info` | built in |

```bash
curl -fsSL https://raw.githubusercontent.com/dylankyc/dy/main/quickstart.sh | LOG_LEVEL=debug bash
```

`debug` adds the HTTP client's own tracing (connection reuse, TLS, retries); `warn` reduces it to
problems only — including the startup route dump, which is `info`.

> A bare word that isn't a level (`LOG_LEVEL=inof`) is **rejected with a warning**, not handed to
> the filter parser: `RUST_LOG` syntax reads an unknown word as a *target* name, which would
> silently disable every log line — the exact opposite of what you wanted when you turned logging
> up.

---

## 10. Image variants

| tag | base | size | |
|---|---|---|---|
| `:latest`, `:v0.1.11` | `debian:bookworm-slim` | 116 MB | has curl → `HEALTHCHECK`, `docker exec` works; uid 10001 |
| `:latest-distroless`, `:v0.1.11-distroless` | `gcr.io/distroless/cc-debian12` | **40 MB** | no shell, no package manager, nothing to exec into; uid 65532 |

```bash
curl -fsSL …/quickstart.sh | IMAGE=docker.io/dylandylandy/dy:latest-distroless bash
```

The distroless image has no `HEALTHCHECK` — there is no curl or shell to run one. Kubernetes and
Nomad do their own HTTP probes, so this only matters for bare `docker run`:

```yaml
livenessProbe:
  httpGet: { path: /health, port: 8000 }
```

---

## 11. Operations

```bash
quickstart.sh status                 # container state, /health, alias list
quickstart.sh logs                   # follow; one line per request from the observer hook
quickstart.sh restart
quickstart.sh down
IMAGE=docker.io/dylandylandy/dy:v0.1.11 quickstart.sh up    # pin a version
```

Routes live in `~/.ai-gateway/gateway.config.yml` (mounted read-only at `/etc/gateway/config.yml`),
credentials in `~/.ai-gateway/.env`. Both are re-read on `up`.

---

## 12. Troubleshooting

| symptom | cause / fix |
|---|---|
| `404 unknown model: X` | the alias isn't in your config — `curl …/v1/models` |
| a **404 from some other server** | your client is pointed at the wrong port. `curl -i localhost:<port>/health` — if the response carries a `Server:` header (nginx, kong, …) that isn't the gateway. The installer refuses to start on a busy port and names the occupant. `:8000` is contested territory: Kong, Django and plenty of dev servers default to it. |
| `404` on a path with `//` | some clients join `base_url` and the path naively: `base_url = "…/v1/"` + `/chat/completions` → `/v1//chat/completions`, which the gateway does not route. Drop the trailing slash. (Codex normalises it; not everything does.) |
| `404 Model not found Y` (upstream) | the provider won't serve that `wire_id` for your account |
| `502 … builder error` on `azure` | `AZURE_ENDPOINT` missing — set it alongside `AZURE_API_KEY` |
| `403` on `bedrock-*` | usually an **empty** `AWS_SESSION_TOKEN`; remove the line entirely |
| empty content, `finish_reason: length` | reasoning models (`gemini-2.5-flash`) spend the budget on thinking — raise `max_tokens` |
| `no conversion path for surface=…` | that surface × dialect pair isn't implemented (see §5) |
| `400 context_management` | Claude Code without `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` — see §7 |
| `400 … Extra inputs are not permitted` | a field the host schema doesn't know. Bedrock/Vertex are filtered to their invoke schema; native Anthropic forwards everything |
| `400 thinking: Input tag 'adaptive'…` or `400 Unexpected role "system"` | fixed in v0.1.8 — upgrade (`quickstart.sh` pulls `:latest`) |
| `UnknownOperationException` from Bedrock (with a **200**) | an ARN `wire_id` whose `/` was splitting the URL path — fixed in v0.1.9 |
| ``400 `temperature` is deprecated for this model`` | that model dropped the parameter; the client still sends it. Use a model that accepts it, or stop sending it |
| `400 tool type '…' is not supported` | a **server-side** tool (`web_search`, `code_execution`) aimed at a host that doesn't run them. Filtered automatically for Bedrock/Vertex since v0.1.10; native Anthropic keeps them |
| `statfs … no such file` on start | VM-backed engine can't mount that path — keep `AI_GATEWAY_HOME` under `$HOME` |
| `port is already allocated` | something else owns it — `PORT=8001 quickstart.sh up`, then update your client's `base_url` to match |
| everything 000 / connection refused | `quickstart.sh status`, then `quickstart.sh logs` |

---

## What's behind it

A Rust crate stack: a sans-io conversion core (`llm-convert`), a delivery layer
(`llm-transport`), and an orchestration crate that owns routing, load-balanced failover and the
request lifecycle. Cross-cutting policy — auth, rate limiting, observability — is a set of hooks
with no-op defaults, so a host can install its own without forking the gateway.
