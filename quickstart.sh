#!/usr/bin/env bash
# Gateway Server quickstart — the Rust-native LLM gateway (gateway-server), plus its
# observability stack (ClickHouse + OTel Collector + Grafana) so every request's `gen_ai.*` span —
# including the full request/response body — lands somewhere queryable with no extra setup.
# Guide: https://github.com/dylankyc/dy
#
#   curl -fsSL https://raw.githubusercontent.com/dylankyc/dy/main/quickstart.sh | bash
#   curl -fsSL … | bash -s -- test          # up | down | restart | logs | status | test | models
#
# This file is mirrored to github.com/dylankyc/dy (the curl-able copy) from
# deploy/gateway-server/quickstart.sh in the gateway repo. Keep them identical.
#
#   LOG_LEVEL=debug … | bash            # error|warn|info|debug|trace (RUST_LOG also honoured)
#   VARIANT=debian  … | bash            # opt out of the distroless image (see VARIANT below)
#   OTEL=0          … | bash            # gateway only — skip ClickHouse/Collector/Grafana
#
# What it does, and nothing else:
#   1. finds a container engine (docker, else podman);
#   2. materialises  $GATEWAY_SERVER_HOME/{gateway.config.yml,.env,otel-collector-config.yaml,
#      grafana-datasource.yaml}  (routes, credentials, tracing pipeline config);
#   3. creates a user-defined network so the containers can resolve each other by name;
#   4. runs docker.io/dylandylandy/dy:latest-distroless (gateway) plus, unless OTEL=0, ClickHouse
#      + an OTel Collector + Grafana, and waits for /health.
#
# No compose: everything is a plain `docker run` on one user-defined bridge network, same
# mechanism the root gateway uses, just four containers instead of one.
set -eu

# Image variant. **distroless by default**: no shell, no package manager, nothing to exec into if
# something gets a foothold, and ~65% smaller. Opt out when you want the batteries:
#
#   VARIANT=debian …/quickstart.sh     # debian-slim + curl → container HEALTHCHECK, `docker exec`
#   TAG=v0.1.12    …/quickstart.sh     # pin a version (applies to either variant)
#   IMAGE=ghcr.io/me/mine:dev …        # bypass both and name the image outright
VARIANT=${VARIANT:-distroless}
TAG=${TAG:-latest}
case "$VARIANT" in
  distroless) IMAGE=${IMAGE:-docker.io/dylandylandy/dy:$TAG-distroless} ;;
  debian)     IMAGE=${IMAGE:-docker.io/dylandylandy/dy:$TAG} ;;
  *) printf 'unknown VARIANT: %s (want: distroless | debian)\n' "$VARIANT" >&2; exit 2 ;;
esac
PORT=${PORT:-8000}
# Loopback by default, deliberately: the gateway does not authenticate clients, so anything that
# can reach this port can spend your provider credits. Put it on the network only when you mean
# to: BIND=0.0.0.0 …/quickstart.sh
BIND=${BIND:-127.0.0.1}
NAME=${NAME:-gateway-server}
NET=${NET:-gateway-server-net}
OTEL=${OTEL:-1}
CH_HTTP_PORT=${CH_HTTP_PORT:-8123}
CH_NATIVE_PORT=${CH_NATIVE_PORT:-9000}
COLLECTOR_GRPC_PORT=${COLLECTOR_GRPC_PORT:-4317}
COLLECTOR_HTTP_PORT=${COLLECTOR_HTTP_PORT:-4318}
GRAFANA_PORT=${GRAFANA_PORT:-3000}
LOG_LEVEL=${LOG_LEVEL:-info}
RAW_BASE=${RAW_BASE:-https://raw.githubusercontent.com/dylankyc/dy/main}
BASE=${BASE:-http://127.0.0.1:$PORT}
GRAFANA_BASE=${GRAFANA_BASE:-http://127.0.0.1:$GRAFANA_PORT}
CMD=${1:-up}

case "$0" in
  bash|sh|-bash|-sh|/dev/fd/*|/proc/self/fd/*)
    SELF="curl -fsSL $RAW_BASE/quickstart.sh | bash -s --"
    self_env() { printf 'curl -fsSL %s/quickstart.sh | %s bash -s --' "$RAW_BASE" "$1"; } ;;
  *)
    SELF=$0
    self_env() { printf '%s %s' "$1" "$0"; } ;;
esac

if [ -t 1 ]; then G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; Z=$'\033[0m'
else G=""; Y=""; R=""; B=""; Z=""; fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '  %s·%s %s\n' "$Y" "$Z" "$*"; }
die()  { printf '  %s✗%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }

# ── container engine ─────────────────────────────────────────────────────────
ENGINE=${ENGINE:-}
if [ -z "$ENGINE" ]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ENGINE=docker
  elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    ENGINE=podman
  else
    die "no running container engine. Start Docker Desktop, or \`podman machine start\`,
    or install one:  https://docs.docker.com/get-docker/  |  https://podman.io/get-started"
  fi
fi

# ── where state lives ────────────────────────────────────────────────────────
if [ -f "$PWD/gateway.config.yml" ] && [ -f "$PWD/quickstart.sh" ]; then
  GW_HOME=$PWD
else
  GW_HOME=${GATEWAY_SERVER_HOME:-$HOME/.gateway-server}
fi
mkdir -p "$GW_HOME"
cd "$GW_HOME"

MOUNT_OPT=ro
if [ "$ENGINE" = podman ] && command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
  MOUNT_OPT=ro,Z
fi

# ── routes: gateway.config.yml ───────────────────────────────────────────────
ensure_config() {
  if [ -f gateway.config.yml ]; then
    ok "routes    gateway.config.yml (keeping yours)"
  elif curl -fsSL "$RAW_BASE/gateway.config.yml" -o gateway.config.yml 2>/dev/null; then
    ok "routes    gateway.config.yml (fetched)"
  else
    die "could not fetch gateway.config.yml and no local copy exists — check network access, or
    drop one at $GW_HOME/gateway.config.yml yourself (see $RAW_BASE/gateway.config.yml)"
  fi
}

# ── tracing pipeline config (static, no secrets — always safe to (re)fetch or embed) ──────────
ensure_otel_config() {
  if [ ! -f otel-collector-config.yaml ]; then
    curl -fsSL "$RAW_BASE/otel-collector-config.yaml" -o otel-collector-config.yaml 2>/dev/null \
      || embedded_otel_collector_config > otel-collector-config.yaml
  fi
  mkdir -p grafana-provisioning/datasources
  if [ ! -f grafana-provisioning/datasources/clickhouse.yaml ]; then
    curl -fsSL "$RAW_BASE/grafana-provisioning/datasources/clickhouse.yaml" \
      -o grafana-provisioning/datasources/clickhouse.yaml 2>/dev/null \
      || embedded_grafana_datasource > grafana-provisioning/datasources/clickhouse.yaml
  fi
}

embedded_otel_collector_config() {
  cat <<'YAML'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        max_recv_msg_size_mib: 40
      http:
        endpoint: 0.0.0.0:4318
processors:
  batch:
    timeout: 1s
    send_batch_size: 1024
exporters:
  clickhouse:
    endpoint: tcp://clickhouse:9000?dial_timeout=10s
    database: otel
    create_schema: true
    ttl: 72h
    timeout: 5s
    sending_queue:
      queue_size: 1000
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhouse, debug]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhouse]
  telemetry:
    logs:
      level: info
YAML
}

embedded_grafana_datasource() {
  cat <<'YAML'
apiVersion: 1
datasources:
  - name: ClickHouse-Traces
    type: grafana-clickhouse-datasource
    access: proxy
    isDefault: true
    editable: true
    jsonData:
      defaultDatabase: otel
      port: 9000
      server: clickhouse
      username: default
      protocol: native
      tlsSkipVerify: true
      traces:
        defaultDatabase: otel
        defaultTable: otel_traces
        otelEnabled: true
        otelVersion: latest
        traceIdColumn: TraceId
        spanIdColumn: SpanId
        parentSpanIdColumn: ParentSpanId
        serviceNameColumn: ServiceName
        operationNameColumn: SpanName
        startTimeColumn: Timestamp
        durationColumn: Duration
        durationUnit: nanoseconds
        tagsColumn: SpanAttributes
        serviceTagsColumn: ResourceAttributes
        kindColumn: SpanKind
        statusCodeColumn: StatusCode
        statusMessageColumn: StatusMessage
        stateColumn: TraceState
        instrumentationLibraryNameColumn: ScopeName
        instrumentationLibraryVersionColumn: ScopeVersion
        flattenNested: false
        traceEventsColumnPrefix: Events
        traceLinksColumnPrefix: Links
      logs:
        defaultDatabase: otel
        defaultTable: otel_logs
        otelEnabled: true
        otelVersion: latest
        timeColumn: Timestamp
        levelColumn: SeverityText
        messageColumn: Body
        traceIdColumn: TraceId
        selectContextColumns: false
    secureJsonData:
      password: ""
YAML
}

# ── credentials: .env ────────────────────────────────────────────────────────
read_file() { [ -f "$1" ] && tr -d '[:space:]' < "$1" || true; }
first_file() { for f in "$@"; do [ -f "$f" ] && { tr -d '[:space:]' < "$f"; return; }; done; }
ensure_env() {
  if [ -f .env ]; then
    ok "creds     .env (keeping yours)"
    return
  fi
  umask 077
  : > .env.tmp
  n=0
  put() { [ -n "${2:-}" ] || return 0; printf '%s=%s\n' "$1" "$2" >> .env.tmp; n=$((n + 1)); }

  oai=${OPENAI_API_KEY:-$(first_file "$HOME/.secret/openai" "$HOME/.secret/openai-secret-qe-kong-260525")}
  ant=${ANTHROPIC_API_KEY:-$(first_file "$HOME/.secret/anthropic" "$HOME/.secret/anthropic-kong-qe-local-debug")}
  gem=${GEMINI_API_KEY:-$(first_file "$HOME/.secret/gemini" "$HOME/.secret/gemini-key-kong-qe")}
  azk=${AZURE_API_KEY:-$(first_file "$HOME/.secret/azure" "$HOME/.secret/azure-api-key-260803")}
  azf=${AZURE_FOUNDRY_API_KEY:-$(first_file "$HOME/.secret/azure-foundry" "$HOME/.secret/azure-foundary-sonnet-4-5")}
  put OPENAI_API_KEY    "$oai"
  put ANTHROPIC_API_KEY "$ant"
  put GEMINI_API_KEY    "$gem"
  put AZURE_API_KEY     "$azk"
  # No file/default fallback for these three, unlike the keys above: an Azure resource host or a
  # GCP project id names real infrastructure, so gateway.config.yml reads them through
  # {vault://env/...} and this script only forwards what's already in *your* environment.
  put AZURE_ENDPOINT "${AZURE_ENDPOINT:-}"
  put AZURE_FOUNDRY_API_KEY "$azf"
  put AZURE_FOUNDRY_ENDPOINT "${AZURE_FOUNDRY_ENDPOINT:-}"
  put VERTEX_PROJECT "${VERTEX_PROJECT:-}"

  akid=${AWS_ACCESS_KEY_ID:-}; asak=${AWS_SECRET_ACCESS_KEY:-}; atok=${AWS_SESSION_TOKEN:-}
  if [ -z "$akid" ] && [ -f "$HOME/.aws/credentials" ]; then
    eval "$(awk '
      /^\[/{ d = ($0=="[default]") }
      d && /aws_access_key_id/     { gsub(/[ \t]/,""); split($0,a,"="); print "akid="a[2] }
      d && /aws_secret_access_key/ { gsub(/[ \t]/,""); split($0,a,"="); print "asak="a[2] }
      d && /aws_session_token/     { gsub(/[ \t]/,""); split($0,a,"="); print "atok="a[2] }
    ' "$HOME/.aws/credentials")"
  fi
  put AWS_ACCESS_KEY_ID "$akid"
  put AWS_SECRET_ACCESS_KEY "$asak"
  put AWS_SESSION_TOKEN "$atok"          # absent ≠ empty: a blank token breaks SigV4
  if [ -n "$akid" ]; then put AWS_REGION "${AWS_REGION:-us-east-1}"; fi

  mantle=${AWS_BEARER_TOKEN_BEDROCK:-$(first_file "$HOME/.secret/bedrock-api-key" "$HOME/.secret/bedrock-short-term-api-key-365day" "$HOME/.secret/bedrock-short-term-api-key-12hours-0806")}
  put AWS_BEARER_TOKEN_BEDROCK "$mantle"

  vtx=${VERTEX_ACCESS_TOKEN:-}
  if [ -z "$vtx" ] && command -v gcloud >/dev/null 2>&1; then
    vtx=$(gcloud auth print-access-token 2>/dev/null || true)
  fi
  put VERTEX_ACCESS_TOKEN "$vtx"

  if [ "$n" = 0 ]; then
    cat > .env <<'ENVTEMPLATE'
# Gateway Server credentials. Fill in what you have — every provider is optional, and the
# aliases backed by a missing key are the only ones that stop working.
OPENAI_API_KEY=
ANTHROPIC_API_KEY=
GEMINI_API_KEY=
# AZURE_API_KEY=
# AZURE_ENDPOINT=https://<your-resource>.openai.azure.com
# AZURE_FOUNDRY_API_KEY=
# AZURE_FOUNDRY_ENDPOINT=https://<your-resource>.services.ai.azure.com
# AWS_BEARER_TOKEN_BEDROCK=       # Bedrock API key → OpenAI models on AWS (Codex reads it too)
# VERTEX_ACCESS_TOKEN=            # gcloud auth print-access-token (expires ~1h)
# VERTEX_PROJECT=                 # your GCP project id
# AWS_ACCESS_KEY_ID=
# AWS_SECRET_ACCESS_KEY=
# AWS_REGION=us-east-1
ENVTEMPLATE
    rm -f .env.tmp
    die "no credentials found. A template is at $GW_HOME/.env — add at least one key, then re-run:
        \$EDITOR $GW_HOME/.env  &&  bash <(curl -fsSL $RAW_BASE/quickstart.sh)"
  fi
  mv .env.tmp .env
  ok "creds     .env ($n variables from your env / ~/.secret / ~/.aws)"
}

models_list() {
  curl -fsS "$BASE/v1/models" 2>/dev/null | tr ',' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | tr '\n' ' '
}

wait_health() {
  for _ in $(seq 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health" 2>/dev/null)" = 200 ] && return 0
    sleep 1
  done
  return 1
}

wait_http() { # wait_http URL
  for _ in $(seq 30); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)" = 200 ] && return 0
    sleep 1
  done
  return 1
}

free_port() {
  for p in 8010 8081 18000 18080; do
    [ "$(curl -s -m 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p/" 2>/dev/null)" = 000 ] && { echo "$p"; return; }
  done
  echo 18085
}
preflight_port() {
  code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$BASE/health" 2>/dev/null) || code=000
  [ "$code" = 000 ] && return 0
  [ "$(curl -s -m 2 "$BASE/health" 2>/dev/null)" = ok ] && return 0
  server=$(curl -s -m 2 -D - -o /dev/null "$BASE/" 2>/dev/null | sed -n 's/^[Ss]erver: *//p' | tr -d '\r' | head -1)
  die "port $PORT is already serving something else${server:+ (Server: $server)}.
    Free it, or pick another port and point your client at the same one:
        $(self_env "PORT=$(free_port)") up"
}

ensure_network() {
  $ENGINE network inspect "$NET" >/dev/null 2>&1 || $ENGINE network create "$NET" >/dev/null
}

up_otel_stack() {
  ensure_otel_config
  ensure_network
  $ENGINE volume create "${NAME}-clickhouse-data" >/dev/null 2>&1 || true
  $ENGINE volume create "${NAME}-grafana-data" >/dev/null 2>&1 || true

  $ENGINE rm -f "${NAME}-clickhouse" "${NAME}-otel-collector" "${NAME}-grafana" >/dev/null 2>&1 || true

  $ENGINE run -d --name "${NAME}-clickhouse" --network "$NET" --network-alias clickhouse \
    -p "$CH_HTTP_PORT:8123" -p "$CH_NATIVE_PORT:9000" \
    -e CLICKHOUSE_DB=otel -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
    -v "${NAME}-clickhouse-data:/var/lib/clickhouse" \
    --restart unless-stopped \
    clickhouse/clickhouse-server:24.10 >/dev/null

  if ! wait_http "http://127.0.0.1:$CH_HTTP_PORT/ping"; then
    warn "clickhouse did not answer on :$CH_HTTP_PORT in time — check: $ENGINE logs ${NAME}-clickhouse"
  fi

  $ENGINE run -d --name "${NAME}-otel-collector" --network "$NET" --network-alias otel-collector \
    -p "$COLLECTOR_GRPC_PORT:4317" -p "$COLLECTOR_HTTP_PORT:4318" \
    -v "$GW_HOME/otel-collector-config.yaml:/etc/otel-collector-config.yaml:$MOUNT_OPT" \
    --restart unless-stopped \
    otel/opentelemetry-collector-contrib:0.110.0 \
    --config=/etc/otel-collector-config.yaml >/dev/null

  $ENGINE run -d --name "${NAME}-grafana" --network "$NET" \
    -p "$GRAFANA_PORT:3000" \
    -e GF_SECURITY_ADMIN_USER=admin -e GF_SECURITY_ADMIN_PASSWORD=admin \
    -e GF_INSTALL_PLUGINS=grafana-clickhouse-datasource \
    -e GF_AUTH_ANONYMOUS_ENABLED=true -e GF_AUTH_ANONYMOUS_ORG_ROLE=Editor \
    -v "$GW_HOME/grafana-provisioning/datasources:/etc/grafana/provisioning/datasources:$MOUNT_OPT" \
    -v "${NAME}-grafana-data:/var/lib/grafana" \
    --restart unless-stopped \
    grafana/grafana:11.4.0 >/dev/null
}

down_otel_stack() {
  $ENGINE rm -f "${NAME}-clickhouse" "${NAME}-otel-collector" "${NAME}-grafana" >/dev/null 2>&1 || true
  $ENGINE network rm "$NET" >/dev/null 2>&1 || true
}

up() {
  say ""
  say "${B}Gateway Server${Z} — $IMAGE via $ENGINE, state in $GW_HOME"
  preflight_port
  ensure_config
  ensure_env
  if [ "$OTEL" = 1 ]; then
    up_otel_stack
  else
    ensure_network
  fi

  $ENGINE pull -q "$IMAGE" >/dev/null 2>&1 || warn "could not refresh $IMAGE — using the local copy"
  $ENGINE rm -f "$NAME" >/dev/null 2>&1 || true
  otel_env=()
  if [ "$OTEL" = 1 ]; then
    otel_env=(-e "OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317" -e "OTEL_SERVICE_NAME=gateway-server")
  else
    otel_env=(-e "OTEL_TRACES_DISABLED=1")
  fi
  if ! err=$($ENGINE run -d --name "$NAME" --network "$NET" \
    -p "$BIND:$PORT:8000" \
    --env-file "$GW_HOME/.env" \
    -e "LOG_LEVEL=$LOG_LEVEL" \
    ${RUST_LOG:+-e "RUST_LOG=$RUST_LOG"} \
    "${otel_env[@]}" \
    -v "$GW_HOME/gateway.config.yml:/etc/gateway/config.yml:$MOUNT_OPT" \
    --restart unless-stopped \
    "$IMAGE" 2>&1); then
    printf '  %s✗%s could not start the container:\n      %s\n' "$R" "$Z" "$err" >&2
    case "$err" in
      *statfs*|*mount*|*"no such file or directory"*)
        say "      hint: $ENGINE cannot bind-mount $GW_HOME. A VM-backed engine (podman on"
        say "            macOS, Docker Desktop) only shares certain host paths — keep"
        say "            GATEWAY_SERVER_HOME under \$HOME (the default is ~/.gateway-server)." ;;
      *"port is already allocated"*|*"address already in use"*|*bind*)
        say "      hint: port $PORT is taken. Re-run with  $(self_env "PORT=$(free_port)") up" ;;
    esac
    exit 1
  fi
  if ! wait_health; then
    printf '  %s✗%s gateway did not become healthy:\n' "$R" "$Z" >&2
    $ENGINE logs "$NAME" 2>&1 | tail -20 >&2
    exit 1
  fi
  ok "gateway   $BASE  (container \"$NAME\", $VARIANT, log level $LOG_LEVEL)"
  if [ "$OTEL" = 1 ]; then
    if wait_http "$GRAFANA_BASE/api/health"; then
      ok "grafana   $GRAFANA_BASE  (admin/admin, or continue anonymously)"
    else
      warn "grafana   $GRAFANA_BASE did not answer in time — check: $ENGINE logs ${NAME}-grafana"
    fi
  fi
  say ""
  say "  models:  $(models_list)"
  say ""
  say "  ${B}try it${Z}"
  say "    curl $BASE/v1/chat/completions -H 'content-type: application/json' \\"
  say "      -d '{\"model\":\"fast\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
  say ""
  if [ "$OTEL" = 1 ]; then
    say "  ${B}see the trace${Z}   open $GRAFANA_BASE → Explore → ClickHouse-Traces (SQL query"
    say "                    mode) — the full request/response body lives in the gen_ai.* span"
    say "                    attributes, not the Logs panel."
    say ""
  fi
  say "  ${B}point a tool at it${Z}"
  say "    Codex        base_url = \"$BASE/v1\", wire_api = \"responses\", model = \"codex\""
  say "    Claude Code  ANTHROPIC_BASE_URL=$BASE  ANTHROPIC_MODEL=claude"
  say "    OpenAI SDKs  OPENAI_BASE_URL=$BASE/v1"
  say ""
  say "  logs: $SELF logs   ·   stop: $SELF down   ·   routes: $GW_HOME/gateway.config.yml"
}

case "$CMD" in
  up) up ;;
  down)
    # Remove every container *before* the network — `network rm` fails silently (a network with
    # an attached container can't be removed) if the gateway container is still on it.
    gw_removed=0
    $ENGINE rm -f "$NAME" >/dev/null 2>&1 && gw_removed=1
    down_otel_stack
    if [ "$gw_removed" = 1 ]; then
      ok "stopped and removed \"$NAME\" and the observability stack"
    else
      warn "\"$NAME\" was not running"
    fi
    ;;
  restart)
    $ENGINE restart "$NAME" >/dev/null && wait_health && ok "restarted \"$NAME\" — $BASE is healthy"
    ;;
  logs)   exec $ENGINE logs -f "${2:-$NAME}" ;;
  status)
    $ENGINE ps --filter "name=^${NAME}(-clickhouse|-otel-collector|-grafana)?$" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health" 2>/dev/null)" = 200 ]; then
      ok "$BASE/health → ok"
      say "  models: $(models_list)"
    else
      warn "$BASE/health unreachable"
    fi
    if [ "$OTEL" = 1 ]; then
      if [ "$(curl -s -o /dev/null -w '%{http_code}' "$GRAFANA_BASE/api/health" 2>/dev/null)" = 200 ]; then
        ok "$GRAFANA_BASE/api/health → ok"
      else
        warn "$GRAFANA_BASE/api/health unreachable"
      fi
    fi
    ;;
  models) say "$(models_list)" ;;
  test)
    m=${2:-fast}
    say "POST $BASE/v1/chat/completions  model=$m"
    body=$(printf '{"model":"%s","max_tokens":256,"messages":[{"role":"user","content":"Reply with exactly the single word: pong"}]}' "$m")
    out=$(printf '%s' "$body" | curl -sS "$BASE/v1/chat/completions" -H 'content-type: application/json' --data-binary @-)
    if command -v jq >/dev/null 2>&1; then
      txt=$(printf '%s' "$out" | jq -r '.choices[0].message.content // ""')
      err=$(printf '%s' "$out" | jq -r '.error.message // ""')
      fin=$(printf '%s' "$out" | jq -r '.choices[0].finish_reason // ""')
      if [ -n "$txt" ]; then say "  → $txt"
      elif [ -n "$err" ]; then say "  ${R}→ $err${Z}"
      else say "  ${Y}→ (empty, finish_reason=$fin — try a larger max_tokens)${Z}"; fi
    else
      say "  → $out"
    fi
    ;;
  *) die "usage: $SELF [up|down|restart|logs [container]|status|models|test [alias]]" ;;
esac
