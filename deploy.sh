#!/usr/bin/env bash
# Deploy the llm-observability stack to a remote VPS.
#
# Defaults target `root@claw`. Override with VPS env var:
#   VPS=root@myvps ./deploy.sh
#
# Subcommands:
#   deploy.sh                 rsync + build + up (default)
#   deploy.sh tailscale-serve (re)apply the Grafana HTTPS serve rule
set -euo pipefail

VPS="${VPS:-root@claw}"
TARGET="${TARGET:-/opt/llm-observability}"
REPO="$(cd "$(dirname "$0")" && pwd)"

info() { echo "[+] $*"; }
die()  { echo "[!] $*" >&2; exit 1; }

deploy() {
  info "Syncing llm-observability to ${VPS}:${TARGET}..."
  ssh "$VPS" "install -d -m 755 ${TARGET}"
  rsync -avz --delete \
    --exclude='.env' --exclude='.git/' \
    "${REPO}/" "${VPS}:${TARGET}/"

  if [[ -f "${REPO}/.env" ]]; then
    rsync -avz "${REPO}/.env" "${VPS}:${TARGET}/.env"
  else
    info "No local .env — ensure ${TARGET}/.env exists on the VPS."
  fi

  info "Starting stack..."
  ssh "$VPS" "cd ${TARGET} && docker compose up -d && docker compose ps"
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
