# Compose CLI detection: docker → podman → docker-compose.
# `<engine> compose version` answers even when that engine's daemon is **down**
# (it only parses the CLI), so probe the daemon with `info` as well — otherwise a
# stopped Docker Desktop beats a running Podman machine and every call fails.
# Override with `make COMPOSE="podman compose" up`.
COMPOSE ?= $(shell \
	if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then \
		echo "docker compose"; \
	elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then \
		echo "podman compose"; \
	elif command -v docker-compose >/dev/null 2>&1; then \
		echo "docker-compose"; \
	else \
		echo "docker compose"; \
	fi \
)

.PHONY: up down verify logs

up:
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down -v

verify:
	COMPOSE="$(COMPOSE)" ./verify.sh

logs:
	$(COMPOSE) logs -f gateway
