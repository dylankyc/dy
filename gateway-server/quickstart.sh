#!/usr/bin/env bash
# Gateway Server quickstart — the Rust-native LLM gateway plus its self-contained observability
# stack (ClickHouse + OTel Collector + Grafana), one command.
#
#   cd gateway-server && ./quickstart.sh                 # up (default) — all 4 services
#   ./quickstart.sh [down|restart|logs|status|models|test [alias]]
#
# IMPORTANT — unlike this repo's root `quickstart.sh` (which pulls a published Docker Hub image
# and needs nothing else), this one builds `gateway-server` **from source**: `Dockerfile.gateway`
# copies `Cargo.toml`/`Cargo.lock`/`crates/`/`third_party/`/`.sqlx/` from the build context, none
# of which live in *this* repo. There is no published gateway-server image yet. Run this from
# inside a checkout of the source repo, with this folder placed at `deploy/gateway-server/` (i.e.
# overwrite/sync that path with this one, or symlink it) — `docker compose`'s `context: ../..`
# then resolves to that repo's actual Cargo workspace root. Running it standalone against a bare
# `git clone` of *this* repo will fail at the build step with a clear "no such file" error, not
# silently.
#
# "Quickstart" here means the *whole pipeline* healthy, not just the gateway on :8000: OTel
# tracing needs somewhere for spans to land, so `up` brings up every service docker-compose.yml
# declares — gateway, clickhouse, otel-collector, grafana — not a subset.
set -eu
cd "$(dirname "$0")"

BASE=${BASE:-http://127.0.0.1:18086}
GRAFANA=${GRAFANA:-http://127.0.0.1:3000}
CMD=${1:-up}

if [ -t 1 ]; then G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; Z=$'\033[0m'
else G=""; Y=""; R=""; B=""; Z=""; fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '  %s·%s %s\n' "$Y" "$Z" "$*"; }
die()  { printf '  %s✗%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }

# Compose CLI detection — `<engine> compose version` answers even when that engine's daemon is
# down (it only parses the CLI), so probe `info` too, or a stopped Docker Desktop beats a running
# Podman machine and every call fails.
COMPOSE=${COMPOSE:-}
if [ -z "$COMPOSE" ]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
     && docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
  elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1 \
     && podman compose version >/dev/null 2>&1; then
    COMPOSE="podman compose"
  elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
    COMPOSE="docker-compose"
  else
    die "no running container engine found. Start Docker Desktop, or \`podman machine start\`,
    or install one:  https://docs.docker.com/get-docker/  |  https://podman.io/get-started"
  fi
fi
compose() { $COMPOSE "$@"; }

wait_health() {
  for _ in $(seq 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health" 2>/dev/null)" = 200 ] && return 0
    sleep 1
  done
  return 1
}

wait_grafana() {
  for _ in $(seq 30); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$GRAFANA/api/health" 2>/dev/null)" = 200 ] && return 0
    sleep 1
  done
  return 1
}

models_list() { # no jq dependency
  curl -fsS "$BASE/v1/models" 2>/dev/null | tr ',' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | tr '\n' ' '
}

# ── credentials: .env ────────────────────────────────────────────────────────
# Self-contained, like the root quickstart.sh's `ensure_env` — no separate gen-secrets.sh here.
# Env wins, then well-known local files; a provider with no credential just stays unavailable.
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
  put AZURE_FOUNDRY_API_KEY "$azf"

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

  # Bedrock Mantle: a Bedrock API key as a Bearer, region-scoped and short-lived — re-run this
  # script after minting a new one.
  mantle=${AWS_BEARER_TOKEN_BEDROCK:-$(first_file "$HOME/.secret/bedrock-api-key" "$HOME/.secret/bedrock-short-term-api-key-365day" "$HOME/.secret/bedrock-short-term-api-key-12hours-0806")}
  put AWS_BEARER_TOKEN_BEDROCK "$mantle"

  # Vertex: a GCP OAuth Bearer that expires in ~1h. Mint it from whatever gcloud is logged in as.
  vtx=${VERTEX_ACCESS_TOKEN:-}
  if [ -z "$vtx" ] && command -v gcloud >/dev/null 2>&1; then
    vtx=$(gcloud auth print-access-token 2>/dev/null || true)
  fi
  put VERTEX_ACCESS_TOKEN "$vtx"

  if [ "$n" = 0 ]; then
    cp .env.example .env 2>/dev/null || : > .env
    rm -f .env.tmp
    die "no credentials found. A template is at $(pwd)/.env — add at least one key, then re-run:
        \$EDITOR .env  &&  ./quickstart.sh"
  fi
  mv .env.tmp .env
  ok "creds     .env ($n variables from your env / ~/.secret / ~/.aws)"
}

up() {
  say ""
  say "${B}Gateway Server${Z} — LLM gateway + observability, via $COMPOSE"
  ensure_env
  if ! compose up -d --build; then
    say ""
    die "build failed. This variant builds gateway-server *from source* — see the note at the
    top of this script. If Dockerfile.gateway's COPY steps report a missing crates/ or
    third_party/, this folder needs to be run from inside a checkout of the source repo (placed
    at deploy/gateway-server/), not standalone."
  fi
  if ! wait_health; then
    printf '  %s✗%s gateway did not become healthy:\n' "$R" "$Z" >&2
    compose logs gateway 2>&1 | tail -20 >&2
    exit 1
  fi
  ok "gateway   $BASE"
  if wait_grafana; then
    ok "grafana   $GRAFANA  (admin/admin, or continue anonymously — both work)"
  else
    warn "grafana   $GRAFANA did not answer in time — check: $COMPOSE logs grafana"
  fi
  say ""
  say "  models:  $(models_list)"
  say ""
  say "  ${B}try it${Z}"
  say "    curl $BASE/v1/chat/completions -H 'content-type: application/json' \\"
  say "      -d '{\"model\":\"fast\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
  say ""
  say "  ${B}see the trace${Z}   open $GRAFANA → Explore → ClickHouse-Traces (SQL query mode) —"
  say "                    the full request/response body lives in the gen_ai.* span"
  say "                    attributes, not the Logs panel. See README.md."
  say ""
  say "  ./quickstart.sh logs   ·   ./quickstart.sh status   ·   ./quickstart.sh down"
}

case "$CMD" in
  up) up ;;
  down) compose down -v && ok "stopped and removed the stack" ;;
  restart)
    compose restart gateway >/dev/null && wait_health && ok "restarted gateway — $BASE is healthy"
    ;;
  logs) exec $COMPOSE logs -f gateway ;;
  status)
    compose ps
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health" 2>/dev/null)" = 200 ]; then
      ok "$BASE/health → ok"
      say "  models: $(models_list)"
    else
      warn "$BASE/health unreachable"
    fi
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "$GRAFANA/api/health" 2>/dev/null)" = 200 ]; then
      ok "$GRAFANA/api/health → ok"
    else
      warn "$GRAFANA/api/health unreachable"
    fi
    ;;
  models) say "$(models_list)" ;;
  test)
    m=${2:-fast}
    say "POST $BASE/v1/chat/completions  model=$m"
    body=$(printf '{"model":"%s","max_tokens":32,"messages":[{"role":"user","content":"Reply with exactly the single word: pong"}]}' "$m")
    out=$(printf '%s' "$body" | curl -sS "$BASE/v1/chat/completions" -H 'content-type: application/json' --data-binary @-)
    if command -v jq >/dev/null 2>&1; then
      txt=$(printf '%s' "$out" | jq -r '.choices[0].message.content // ""')
      err=$(printf '%s' "$out" | jq -r '.error.message // ""')
      if [ -n "$txt" ]; then say "  → $txt"
      elif [ -n "$err" ]; then say "  ${R}→ $err${Z}"
      else say "  ${Y}→ (empty)${Z}"; fi
    else
      say "  → $out"
    fi
    ;;
  *) die "usage: $0 [up|down|restart|logs|status|models|test [alias]]" ;;
esac
