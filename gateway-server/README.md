# gateway-server — the same gateway, a different binary

This variant runs the **Rust-native `gateway-server` binary** (a from-scratch Kong-parity
rewrite, with an LLM plan attached to it) instead of the root `quickstart.sh`'s published
`ffc/llm-gateway`-based image. Same aliases, same providers, same env var names — a different
implementation, not a different set of models.

## The one thing that's different: this builds from source

The root `quickstart.sh` pulls a **pre-built** Docker Hub image, so `curl | bash` works on any
bare machine. There is no published image for `gateway-server` (yet) — `Dockerfile.gateway` here
builds it from the Rust source, and that source is **not in this repo**.

To actually run this, place this folder at `deploy/gateway-server/` inside a checkout of the
source repo (overwrite or symlink it there) — `docker-compose.yml`'s build `context: ../..` then
resolves to that repo's real Cargo workspace root (`Cargo.toml`, `crates/`, `third_party/`,
`.sqlx/`). Run standalone against nothing but this folder and the build fails at the `COPY`
step — clearly, not silently (`quickstart.sh` catches this and says so).

## Quickstart (once placed correctly)

```sh
./quickstart.sh                          # gen .env (if needed) + compose up + health-wait
./quickstart.sh test fast                 # POST /v1/chat/completions, prints the reply
./quickstart.sh down
```

Same subcommands as the root script: `up` (default) `down` `restart` `logs` `status` `models`
`test [alias]`.

## What's different from the root gateway, besides the binary

- **Full observability included**: `docker-compose.yml` also brings up ClickHouse, an OTel
  Collector, and Grafana (`:3000`, `admin`/`admin`, or continue anonymously) — every request's
  `gen_ai.*` span, including the **full** request/response body (no truncation below what's
  buffered — 16 MiB), lands somewhere queryable with no extra setup.
- **Viewing a trace**: open Grafana → Explore → the `ClickHouse-Traces` datasource → switch to
  SQL mode:
  ```sql
  SELECT Timestamp, SpanName, Duration/1000000 AS Ms,
         SpanAttributes['gen_ai.request.model'] AS Model,
         SpanAttributes['gen_ai.request.body']  AS ReqBody,
         SpanAttributes['gen_ai.response.body'] AS RespBody
  FROM otel.otel_traces
  WHERE ServiceName = 'gateway-server' AND SpanName != 'GET /health'
  ORDER BY Timestamp DESC LIMIT 20
  ```
  The request/response content lives in those `gen_ai.*` **span attributes**, not the Logs
  panel — the correlated log lines are short breadcrumbs (`"request received ..."`,
  `"response sent status=..."`) for timing, not content.
- **`/health` is not traced**: the compose healthcheck polls it every 2s for the container's
  whole lifetime; tracing that would dwarf real traffic for no diagnostic value.
- **Config shape**: `gateway.config.yml` here is this binary's own nested `llm:` + `services:`
  shape — provider entries carry the same fields (`kind`, `name`, models with
  `alias`/`wire_id`/`capability`/`max_output_tokens`), but the secret is `credential_ref:
  "{vault://env/VAR}"` rather than `api_key_env: VAR`.

## Ports

`:18086` (gateway), `:3000` (Grafana), `:8123`/`:9000` (ClickHouse), `:4317`/`:4318` (OTel
Collector) — different from the root gateway's `:18085`, so both can run side by side if you also
have the source checkout for this one.

## Credentials

See `.env.example`. Same env var names as the root gateway — a key that works there works here.
