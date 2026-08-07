# dy — AI Gateway (gateway-server)

One endpoint in front of **OpenAI, Anthropic, Google Gemini, Azure OpenAI, Azure AI Foundry, AWS
Bedrock (Claude *and* OpenAI models) and Vertex AI**. You pick the backend with a *model alias*;
the gateway transcodes your request to that provider's dialect and signs it with that provider's
envelope. Your app, your SDK and your coding agent never learn there are eight providers back
there.

Runs `gateway-server` — a Rust-native, from-scratch Kong-parity rewrite with an LLM plan attached
to it — plus a self-contained tracing pipeline (ClickHouse + OTel Collector + Grafana): every
request's full request/response body lands somewhere queryable, no extra setup.

```
   /v1/chat/completions · /v1/messages · /v1/responses · /v1/embeddings · /v1/moderations
                                        │  model: "<alias>"
   ┌──────────┬───────────┬─────────────┼──────────┬──────────────┬──────────────┐
 "fast"    "claude"    "gemini"      "azure"  "azure-claude"   "codex"     "vertex-claude"
   │    (failover pool)     │            │           │        (pool)             │
 openai  anthropic→bedrock gemini  azure openai   foundry   bedrock-mantle→openai  vertex
```

```bash
curl -fsSL https://raw.githubusercontent.com/dylankyc/dy/main/quickstart.sh | bash
```

That's it — a gateway on **http://127.0.0.1:8000** plus Grafana on **http://127.0.0.1:3000**,
ready for `curl`, the OpenAI/Anthropic SDKs, **Codex** and **Claude Code**.

---

## Contents

| file | |
|---|---|
| [`quickstart.sh`](./quickstart.sh) | the bootstrapper — installs, starts, tests, tears down |
| [`gateway.config.yml`](./gateway.config.yml) | the routes: providers, aliases, wire ids |
| [`.env.example`](./.env.example) | the credential slots |
| [`otel-collector-config.yaml`](./otel-collector-config.yaml) | the tracing pipeline: OTLP → ClickHouse |
| [`grafana-provisioning/`](./grafana-provisioning/) | Grafana's auto-provisioned ClickHouse datasource |

The gateway itself ships as `docker.io/dylandylandy/dy` (a Rust binary, `debian-slim` or
distroless, non-root, healthchecked).

---

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/dylankyc/dy/main/quickstart.sh | bash
```

The script finds docker (or podman), writes `~/.gateway-server/{gateway.config.yml,.env,
otel-collector-config.yaml,grafana-provisioning/}`, starts `dylandylandy/dy:latest-distroless`
plus ClickHouse + an OTel Collector + Grafana (all plain `docker run` on one user-defined
network — no compose needed), and waits for `/health`. It is re-runnable and touches nothing
else.

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

**Commands:** `up` (default) · `down` · `restart` · `logs [container]` · `status` · `models` ·
`test [alias]`

| variable | default | |
|---|---|---|
| `PORT` | `8000` | host port for the gateway |
| `BIND` | `127.0.0.1` | **loopback on purpose** — see [Security](#security) |
| `GATEWAY_SERVER_HOME` | `~/.gateway-server` | where config + credentials live |
| `LOG_LEVEL` | `info` | `error`\|`warn`\|`info`\|`debug`\|`trace` |
| `VARIANT` | `distroless` | `distroless` (no shell) or `debian` (curl + `HEALTHCHECK`) |
| `TAG` | `latest` | pin a version, e.g. `v0.1.0` |
| `IMAGE` | derived from `VARIANT`+`TAG` | name an image outright, bypassing both |
| `ENGINE` | auto | force `docker` or `podman` |
| `OTEL` | `1` | set `OTEL=0` to skip ClickHouse/Collector/Grafana — gateway only |
| `GRAFANA_PORT` | `3000` | host port for Grafana |
| `CH_HTTP_PORT` / `CH_NATIVE_PORT` | `8123` / `9000` | host ports for ClickHouse |
| `COLLECTOR_GRPC_PORT` / `COLLECTOR_HTTP_PORT` | `4317` / `4318` | host ports for the OTel Collector |

---

## 2. Credentials

The config names **environment variables**; it never contains a key. The installer fills
`.env` from your shell environment, then `~/.secret/*`, then `~/.aws/credentials`. Every
provider is optional — a missing key only disables its aliases.

```ini
OPENAI_API_KEY=sk-…
ANTHROPIC_API_KEY=sk-ant-…
GEMINI_API_KEY=…
AWS_ACCESS_KEY_ID=…                                  # Bedrock; the gateway signs SigV4 itself
AWS_SECRET_ACCESS_KEY=…
AWS_REGION=us-east-1
```

See `.env.example` for the full list, including Azure/Bedrock Mantle/Vertex.

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
  -d '{"model":"claude","max_tokens":64,"messages":[{"role":"user","content":"Say pong"}]}'

# OpenAI Responses surface (native passthrough for OpenAI/Bedrock Mantle, transcoded for others)
curl http://127.0.0.1:8000/v1/responses -H 'content-type: application/json' \
  -d '{"model":"fast","input":"Say pong"}'

# ops
curl http://127.0.0.1:8000/v1/models      # every alias this gateway serves
curl http://127.0.0.1:8000/health         # → ok
```

An unresolvable alias exhausts its candidates and answers `502` — the gateway never dials a
provider for a model it doesn't know.

---

## 4. Model aliases

An alias is what your client sends; `wire_id` is what the provider is asked for.

| alias | provider | wire id |
|---|---|---|
| `fast` | OpenAI | `gpt-4o-mini` |
| `gpt-4o`, `gpt-4o-mini`, `gpt-5`, `gpt-5.1`, `gpt-5.1-codex`, `gpt-5.1-codex-mini`, `codex`, `openai.gpt-5.6-sol` | OpenAI | pass-through (alias = wire id) or named otherwise |
| `claude` | Anthropic → **failover** → Bedrock | `claude-haiku-4-5-20251001` / `us.anthropic.claude-sonnet-4-…` |
| `bedrock-claude` | Bedrock (SigV4) | `arn:aws:bedrock:...claude-opus-4-8` |
| `gemini` | Google Gemini | `gemini-2.5-flash` |
| `azure` | Azure OpenAI | `gpt-4o-mini` (the *deployment* name) |
| `azure-claude` | Azure AI Foundry | `claude-sonnet-4-5-foundry` (the Foundry *deployment*) |
| `vertex-claude`, `vertex-sonnet-4-5` | Vertex AI | `claude-sonnet-4-6` / `claude-sonnet-4-5@20250929` |
| `codex` | OpenAI → **failover** → Bedrock Mantle | `gpt-5.3-codex` / `openai.gpt-5.6-sol` |
| `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna` | Bedrock Mantle (OpenAI models on AWS) | `openai.gpt-5.6-*` |
| `embed` | OpenAI (`/v1/embeddings`) | `text-embedding-3-small` |
| `moderate` | OpenAI (`/v1/moderations`) | `omni-moderation-latest` |

`gateway.config.yml` is the source of truth — edit it to add your own aliases or repoint an
existing one at a different wire id.

---

## 5. Observability — tracing every request

`quickstart.sh` brings up ClickHouse + an OTel Collector + Grafana alongside the gateway (skip
with `OTEL=0`). Every request gets a span carrying its **full request and response body** (no
truncation below what's buffered — 16 MiB), plus model, token usage, and finish reason.

Open **http://127.0.0.1:3000** (`admin`/`admin`, or continue anonymously — both work) → **Explore**
→ the `ClickHouse-Traces` datasource → switch to SQL mode:

```sql
SELECT Timestamp, SpanName, Duration/1000000 AS Ms,
       SpanAttributes['gen_ai.request.model']  AS Model,
       SpanAttributes['gen_ai.request.body']   AS ReqBody,
       SpanAttributes['gen_ai.response.body']  AS RespBody
FROM otel.otel_traces
WHERE ServiceName = 'gateway-server' AND SpanName != 'GET /health'
ORDER BY Timestamp DESC LIMIT 20
```

The request/response content lives in those `gen_ai.*` **span attributes** — not the Logs panel.
The correlated log lines (same `TraceId`) are short breadcrumbs (`"request received ..."`,
`"response sent status=..."`) for timing, not content. `/health` is deliberately not traced — the
container's own healthcheck polls it every couple of seconds for its whole lifetime, which would
dwarf real traffic for no diagnostic value.

---

## 6. What's not here (yet)

This is `gateway-server`, not the previous `ffc/llm-gateway`-based image — it has full parity on
the surfaces above, but not yet: the Responses API's sub-resource operations (`GET`/`DELETE
/v1/responses/{id}`, `.../cancel`, `.../input_items`), files, batches, audio/image, and
realtime's WebRTC/WebSocket sideband. Each needs a long-lived singleton threaded through server
bootstrap — real work, not yet done.

---

## Security

`quickstart.sh` binds the gateway to `127.0.0.1` by default. The gateway does not authenticate
clients out of the box — anything that can reach the port can spend your provider credits.
`BIND=0.0.0.0` only if you put your own auth or network policy in front of it.

---

## Operations

```bash
quickstart.sh status    # container health + advertised models
quickstart.sh logs               # gateway logs, follow
quickstart.sh logs gateway-server-grafana   # any of the 4 containers by name
quickstart.sh down       # stop and remove everything (containers + network)
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `no running container engine` | Docker Desktop stopped / no podman machine | Start Docker Desktop, or `podman machine start` |
| A model returns `502` | The alias has no credential configured, or every candidate failed | `quickstart.sh status` shows advertised models; check `.env` |
| Grafana Explore says "Missing time field" | A stale/customized datasource file | Delete `~/.gateway-server/grafana-provisioning` and re-run `up` to refetch the default |
| Port already in use | Something else is on `:8000`/`:3000`/etc. | `PORT=... GRAFANA_PORT=... quickstart.sh up` |

---

## What's behind it

`gateway-server` — a Rust-native, from-scratch Kong-parity gateway (routing, plugins, admin API)
with an LLM plan attached to it, replacing the earlier `ffc/llm-gateway` prototype this image
used to run. Source: the private `kong-work` repo (`deploy/gateway-server/`) — this repo mirrors
just the pieces a user needs to run it.
