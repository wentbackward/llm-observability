#!/usr/bin/env bash
# Deploy the llm-observability stack to a remote VPS.
#
# Configuration is read from .env (gitignored). Required:
#   VPS=root@myvps              # ssh target
# Optional:
#   TARGET=/opt/llm-observability  # remote install path (default shown)
#
# Both can also be passed inline: VPS=root@myvps ./deploy.sh
#
# Subcommands:
#   deploy.sh                 rsync + build + up (default)
#   deploy.sh tailscale-serve (re)apply the Grafana HTTPS serve rule
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"

if [[ -f "${REPO}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO}/.env"
  set +a
fi

: "${VPS:?VPS must be set (in .env or environment), e.g. VPS=root@myvps}"
TARGET="${TARGET:-/opt/llm-observability}"

info() { echo "[+] $*"; }
warn() { echo "[~] $*"; }
die()  { echo "[!] $*" >&2; exit 1; }

# Volumes are declared external in compose.yml — make sure they exist
# before `compose up` so a fresh VPS deploy isn't a special case. Idempotent.
ensure_volume() {
  local name="$1"
  if ssh "$VPS" "docker volume inspect ${name} >/dev/null 2>&1"; then
    return 0
  fi
  warn "Volume ${name} missing on ${VPS} — creating empty volume."
  warn "    (If you intended to adopt an existing volume, abort and check the name.)"
  ssh "$VPS" "docker volume create ${name}" >/dev/null
}

deploy() {
  info "Syncing llm-observability to ${VPS}:${TARGET}..."
  ssh "$VPS" "install -d -m 755 ${TARGET}"
  # Whitelist: only ship what compose actually needs at runtime.
  # Anything not listed here is denied AND removed from the target on each
  # deploy (--delete-excluded). .env is protected and shipped separately.
  #
  # --inplace preserves inodes. Critical for prometheus.yml: compose binds
  # it as a single file, and Docker pins the original inode at mount time.
  # Without --inplace, rsync's temp-file-then-rename leaves the container
  # reading the pre-deploy version forever.
  rsync -avz --inplace --delete --delete-excluded \
    --filter='P /.env' \
    --include='/compose.yml' \
    --include='/prometheus.yml' \
    --include='/grafana/' \
    --include='/grafana/**' \
    --exclude='*' \
    "${REPO}/" "${VPS}:${TARGET}/"

  if [[ -f "${REPO}/.env" ]]; then
    rsync -avz "${REPO}/.env" "${VPS}:${TARGET}/.env"
  else
    info "No local .env — ensure ${TARGET}/.env exists on the VPS."
  fi

  ensure_volume "${PROMETHEUS_VOLUME:-llm-observability_prometheus-data}"
  ensure_volume "${GRAFANA_VOLUME:-llm-observability_grafana-data}"

  info "Starting stack..."
  ssh "$VPS" "cd ${TARGET} && docker compose up -d && docker compose ps"

  # Prometheus reloads its config on SIGHUP. Cheap to do unconditionally —
  # a no-op if compose just recreated the container.
  info "Reloading prometheus config..."
  ssh "$VPS" "docker kill --signal=HUP prometheus" >/dev/null
}

apply_tailscale_serve() {
  # Read GRAFANA_HOST_PORT from local .env if present, else fall back to 3033.
  local port=3033
  if [[ -f "${REPO}/.env" ]]; then
    local v
    v=$(grep -E '^GRAFANA_HOST_PORT=' "${REPO}/.env" | tail -1 | cut -d= -f2- || true)
    [[ -n "$v" ]] && port="$v"
  fi
  info "Applying tailscale serve: https/${port} → http://127.0.0.1:${port}"
  ssh "$VPS" "tailscale serve --bg --https=${port} http://127.0.0.1:${port} && tailscale serve status"
}

case "${1:-deploy}" in
  deploy)           deploy ;;
  tailscale-serve)  apply_tailscale_serve ;;
  *)                die "Unknown command: $1" ;;
esac
