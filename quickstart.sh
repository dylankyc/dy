#!/usr/bin/env bash
# AI Gateway quickstart — one OpenAI-compatible endpoint in front of OpenAI, Anthropic, Gemini,
# Azure OpenAI and Bedrock, addressed by *model alias*. Guide: https://github.com/dylankyc/dy
#
#   curl -fsSL https://raw.githubusercontent.com/dylankyc/dy/main/quickstart.sh | bash
#   curl -fsSL … | bash -s -- test          # up | down | restart | logs | status | test | models
#
# This file is mirrored to github.com/dylankyc/dy (the curl-able copy) from
# deploy/ai-gateway/quickstart.sh in the gateway repo. Keep them identical.
#
#   LOG_LEVEL=debug … | bash            # error|warn|info|debug|trace (RUST_LOG also honoured)
#   VARIANT=debian  … | bash            # opt out of the distroless image (see VARIANT below)
#
# What it does, and nothing else:
#   1. finds a container engine (docker, else podman);
#   2. materialises  $AI_GATEWAY_HOME/gateway.config.yml  (routes)  and  .env  (credentials);
#   3. runs docker.io/dylandylandy/dy:latest-distroless on :8000 and waits for /health.
#
# The distroless image carries no HEALTHCHECK (it has no curl or shell to run one), so `status`
# probes /health over HTTP itself rather than reading the engine's health column.
#
# Everything lives under $AI_GATEWAY_HOME (default ~/.ai-gateway); re-running is safe. Credentials
# are read from your environment, else from ~/.secret/* and ~/.aws/credentials, and are written
# only to that .env — never into the image, never into the config.
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
# Loopback by default, deliberately: the gateway does not authenticate clients (the auth hook is
# a no-op unless a host installs one), so anything that can reach this port can spend your
# provider credits. Put it on the network only when you mean to: BIND=0.0.0.0 …/quickstart.sh
BIND=${BIND:-127.0.0.1}
NAME=${NAME:-ai-gateway}
# Verbosity: error|warn|info|debug|trace. RUST_LOG (full filter syntax) outranks it if exported.
LOG_LEVEL=${LOG_LEVEL:-info}
RAW_BASE=${RAW_BASE:-https://raw.githubusercontent.com/dylankyc/dy/main}
BASE=${BASE:-http://127.0.0.1:$PORT}
CMD=${1:-up}

# $0 is "bash" when this script is piped from curl, which makes "$0 logs" useless advice.
# It also moves where an env var has to go: `PORT=8081 curl … | bash` sets it for *curl*.
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
# `docker` may be installed with Docker Desktop stopped while a podman machine is up, so probe
# the daemon, not just the CLI.
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
# Run from a checkout of deploy/ai-gateway and it uses those files in place; run it anywhere
# else (the curl-into-bash case) and it sets up ~/.ai-gateway.
if [ -f "$PWD/gateway.config.yml" ] && [ -f "$PWD/quickstart.sh" ]; then
  GW_HOME=$PWD
else
  GW_HOME=${AI_GATEWAY_HOME:-$HOME/.ai-gateway}
fi
mkdir -p "$GW_HOME"
cd "$GW_HOME"

# SELinux hosts reject a plain bind mount from $HOME; :Z relabels it for the container.
MOUNT_OPT=ro
if [ "$ENGINE" = podman ] && command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
  MOUNT_OPT=ro,Z
fi

# The offline fallback for gateway.config.yml: a snapshot of the published file, so a machine
# with no route to raw.githubusercontent.com still gets a working gateway. The fetch above is
# preferred — it picks up aliases added since this script was cut.
embedded_config() {
  cat <<'YAML'
# AI Gateway (ffc/llm-gateway) — real multi-provider config with model aliases.
#
# One OpenAI-compatible surface (POST /v1/chat/completions) fans out to five real providers.
# Clients always send an OpenAI request; the gateway transcodes per target dialect and signs
# per target envelope (doc/0172). Secrets are read from the named env vars at build time — never
# stored here; gen-secrets.sh materialises them into .env from ~/.secret and ~/.aws/credentials,
# and docker-compose.yml injects them into the container.

server:
  # Container-side bind; compose publishes it on the host as :18085.
  listen: "0.0.0.0:8000"

providers:
  # ── OpenAI (native, Bearer) ────────────────────────────────────────────────
  - kind: openai
    name: openai
    api_key_env: OPENAI_API_KEY
    models:
      # max_output_tokens clamps a client's max_tokens on cross-adapter transcodes: Claude Code
      # (Anthropic surface) sizes max_tokens for a Claude model (32k), but gpt-4o* caps at 16384.
      - alias: fast                # client sends model:"fast"
        wire_id: gpt-4o-mini       # → OpenAI /v1/chat/completions (or /v1/responses)
        max_output_tokens: 16384
      # Pass-through aliases (alias == wire id) so OpenAI-native clients (e.g. Codex, which uses
      # wire_api="responses") can send the real model name and reach OpenAI unchanged.
      - { alias: gpt-4o-mini,        wire_id: gpt-4o-mini, max_output_tokens: 16384 }
      - { alias: gpt-4o,             wire_id: gpt-4o,      max_output_tokens: 16384 }
      - { alias: gpt-5-mini,         wire_id: gpt-5-mini }
      - { alias: gpt-5,              wire_id: gpt-5 }
      - { alias: gpt-5.1,            wire_id: gpt-5.1 }
      - { alias: gpt-5.1-codex,      wire_id: gpt-5.1-codex }
      - { alias: gpt-5.1-codex-mini, wire_id: gpt-5.1-codex-mini }

  # ── Anthropic (native, x-api-key) — PRIMARY for the "claude" alias ─────────
  - kind: anthropic
    name: anthropic
    api_key_env: ANTHROPIC_API_KEY
    models:
      # shared alias → failover pool (anthropic, then bedrock)
      # transcode OpenAI→Anthropic → api.anthropic.com/v1/messages
      - alias: claude
        wire_id: claude-haiku-4-5-20251001

  # ── Bedrock (Claude via SigV4) — SECONDARY for "claude", plus a direct alias ─
  # Same `claude` alias registered here too → routes["claude"] = [anthropic:claude,
  # bedrock:claude], so a client model:"claude" fails over from Anthropic to Bedrock.
  # `bedrock-claude` addresses it directly (exercises SigV4 signing through the gateway).
  - kind: bedrock
    name: bedrock
    region: us-east-1
    models:
      - alias: claude
        wire_id: "us.anthropic.claude-haiku-4-5-20251001-v1:0"
      - alias: bedrock-claude
        wire_id: "us.anthropic.claude-haiku-4-5-20251001-v1:0"

  # ── Gemini (native, x-goog-api-key, model in the URL) — transcoded from OpenAI ─
  - kind: gemini
    name: gemini
    api_key_env: GEMINI_API_KEY
    models:
      # transcode OpenAI→Gemini → …/models/gemini-2.5-flash:generateContent
      - alias: gemini
        wire_id: gemini-2.5-flash

  # ── Azure OpenAI (deployment-addressed, Bearer + api-version) ──────────────
  - kind: azure-openai
    name: azure
    endpoint_env: AZURE_ENDPOINT     # e.g. https://<resource>.openai.azure.com
    api_key_env: AZURE_API_KEY
    api_version: "2025-01-01-preview"
    models:
      - alias: azure
        wire_id: gpt-4o-mini         # the Azure *deployment* name (goes in the URL path)
        max_output_tokens: 16384     # clamp cross-adapter max_tokens (Claude Code → Azure)
YAML
}

# ── routes: gateway.config.yml ───────────────────────────────────────────────
# Prefer the published file (so you get today's aliases); fall back to the copy baked in below
# when offline. Yours is never overwritten.
ensure_config() {
  if [ -f gateway.config.yml ]; then
    ok "routes    gateway.config.yml (keeping yours)"
  elif curl -fsSL "$RAW_BASE/gateway.config.yml" -o gateway.config.yml 2>/dev/null; then
    ok "routes    gateway.config.yml (fetched)"
  else
    embedded_config > gateway.config.yml
    ok "routes    gateway.config.yml (built-in default — offline)"
  fi
}

# ── credentials: .env ────────────────────────────────────────────────────────
# The config names env vars; this fills them. Env wins, then the well-known files. A provider
# with no credential is simply absent — the others still work.
read_file() { [ -f "$1" ] && tr -d '[:space:]' < "$1" || true; }
ensure_env() {
  if [ -f .env ]; then
    ok "creds     .env (keeping yours)"
    return
  fi
  umask 077
  : > .env.tmp
  n=0
  put() { # put NAME VALUE
    [ -n "${2:-}" ] || return 0
    printf '%s=%s\n' "$1" "$2" >> .env.tmp
    n=$((n + 1))
  }
  # Resolve every value *first*, then write: the guards below need the resolved value, and
  # `${AZURE_API_KEY:-}` is empty when the key came from a file rather than the environment
  # (which silently dropped AZURE_ENDPOINT, and Azure then 502s with "builder error").
  oai=${OPENAI_API_KEY:-$(read_file "$HOME/.secret/openai-secret-qe-kong-260525")}
  ant=${ANTHROPIC_API_KEY:-$(read_file "$HOME/.secret/anthropic-kong-qe-local-debug")}
  gem=${GEMINI_API_KEY:-$(read_file "$HOME/.secret/gemini-key-kong-qe")}
  azk=${AZURE_API_KEY:-$(read_file "$HOME/.secret/azure-api-key-260803")}
  put OPENAI_API_KEY    "$oai"
  put ANTHROPIC_API_KEY "$ant"
  put GEMINI_API_KEY    "$gem"
  put AZURE_API_KEY     "$azk"
  # Azure is deployment-addressed: the key alone is useless without the resource endpoint.
  if [ -n "$azk" ]; then
    put AZURE_ENDPOINT "${AZURE_ENDPOINT:-https://ai-gw-sdet-e2e-test.openai.azure.com}"
  fi

  # AWS: env first, else the [default] profile — the gateway signs SigV4 itself and reads keys
  # from the environment, so the profile has to be flattened.
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

  if [ "$n" = 0 ]; then
    cat > .env <<'ENVTEMPLATE'
# AI Gateway credentials. Fill in what you have — every provider is optional, and the aliases
# backed by a missing key are the only ones that stop working.
OPENAI_API_KEY=
ANTHROPIC_API_KEY=
GEMINI_API_KEY=
# AZURE_API_KEY=
# AZURE_ENDPOINT=https://<your-resource>.openai.azure.com
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

models_list() { # no jq dependency
  curl -fsS "$BASE/v1/models" 2>/dev/null | tr ',' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | tr '\n' ' '
}

wait_health() {
  for _ in $(seq 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health" 2>/dev/null)" = 200 ] && return 0
    sleep 1
  done
  return 1
}

# Refuse to fight over the port. Something else answering here is the single most confusing
# failure mode: the container starts (or doesn't), your client talks to the *other* service, and
# you get its 404s instead of ours — e.g. a local Kong on :8000 answering /v1/chat/completions.
free_port() { # first candidate nothing is listening on — don't suggest a port that is also taken
  for p in 8010 8081 18000 18080; do
    [ "$(curl -s -m 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p/" 2>/dev/null)" = 000 ] && { echo "$p"; return; }
  done
  echo 18085
}
preflight_port() {
  # `$(curl … || echo 000)` would *concatenate*: a failed curl prints 000 on its own and then the
  # fallback adds a second one, so `code` becomes "000\n000" and every free port looks occupied.
  code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$BASE/health" 2>/dev/null) || code=000
  [ "$code" = 000 ] && return 0                       # free
  [ "$(curl -s -m 2 "$BASE/health" 2>/dev/null)" = ok ] && return 0   # our gateway; we recreate it
  server=$(curl -s -m 2 -D - -o /dev/null "$BASE/" 2>/dev/null | sed -n 's/^[Ss]erver: *//p' | tr -d '\r' | head -1)
  die "port $PORT is already serving something else${server:+ (Server: $server)}.
    Free it, or pick another port and point your client at the same one:
        $(self_env "PORT=$(free_port)") up"
}

up() {
  say ""
  say "${B}AI Gateway${Z} — $IMAGE via $ENGINE, state in $GW_HOME"
  preflight_port
  ensure_config
  ensure_env
  $ENGINE pull -q "$IMAGE" >/dev/null 2>&1 || warn "could not refresh $IMAGE — using the local copy"
  $ENGINE rm -f "$NAME" >/dev/null 2>&1 || true
  if ! err=$($ENGINE run -d --name "$NAME" \
    -p "$BIND:$PORT:8000" \
    --env-file "$GW_HOME/.env" \
    -e "LOG_LEVEL=$LOG_LEVEL" \
    ${RUST_LOG:+-e "RUST_LOG=$RUST_LOG"} \
    -v "$GW_HOME/gateway.config.yml:/etc/gateway/config.yml:$MOUNT_OPT" \
    --restart unless-stopped \
    "$IMAGE" 2>&1); then
    printf '  %s✗%s could not start the container:\n      %s\n' "$R" "$Z" "$err" >&2
    case "$err" in
      *statfs*|*mount*|*"no such file or directory"*)
        say "      hint: $ENGINE cannot bind-mount $GW_HOME. A VM-backed engine (podman on"
        say "            macOS, Docker Desktop) only shares certain host paths — keep"
        say "            AI_GATEWAY_HOME under \$HOME (the default is ~/.ai-gateway)." ;;
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
  say ""
  say "  models:  $(models_list)"
  say ""
  say "  ${B}routes${Z}   $SELF logs   — every alias and its failover chain is logged at startup"
  say ""
  say "  ${B}try it${Z}"
  say "    curl $BASE/v1/chat/completions -H 'content-type: application/json' \\"
  say "      -d '{\"model\":\"fast\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
  say ""
  say "  ${B}point a tool at it${Z}"
  say "    Codex        base_url = \"$BASE/v1\", wire_api = \"responses\""
  say "    Claude Code  ANTHROPIC_BASE_URL=$BASE  ANTHROPIC_MODEL=fast"
  say "    OpenAI SDKs  OPENAI_BASE_URL=$BASE/v1"
  say "    full guide   https://github.com/dylankyc/dy"
  say ""
  say "  logs: $SELF logs   ·   stop: $SELF down   ·   routes: $GW_HOME/gateway.config.yml"
}

case "$CMD" in
  up) up ;;
  down)
    $ENGINE rm -f "$NAME" >/dev/null 2>&1 && ok "stopped and removed \"$NAME\"" || warn "\"$NAME\" was not running"
    ;;
  restart)
    $ENGINE restart "$NAME" >/dev/null && wait_health && ok "restarted \"$NAME\" — $BASE is healthy"
    ;;
  logs)   exec $ENGINE logs -f "$NAME" ;;
  status)
    # Anchored: `name=ai-gateway` is a substring match and would also list the compose demo's
    # gw-ai-gateway-gateway-1, reporting the wrong container's ports.
    $ENGINE ps --filter "name=^${NAME}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health" 2>/dev/null)" = 200 ]; then
      ok "$BASE/health → ok"
      say "  models: $(models_list)"
    else
      warn "$BASE/health unreachable"
    fi
    ;;
  models) say "$(models_list)" ;;
  test)
    m=${2:-fast}
    say "POST $BASE/v1/chat/completions  model=$m"
    # 256, not 16: reasoning models (gemini-2.5-flash) spend the budget on thinking tokens and
    # return empty content with finish_reason=length if you size it for a plain chat reply.
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
  *) die "usage: $SELF [up|down|restart|logs|status|models|test [alias]]" ;;
esac
