# llm-observability

A pre-configured Prometheus + Grafana stack for monitoring self-hosted LLM infrastructure over a Tailscale network. TLS termination is handled by `tailscale serve` on the host — no cert rotation, no reverse-proxy container.

Designed as a companion to:

- [`llm-proxy`](https://github.com/wentbackward/llm-proxy) — OpenAI-compatible proxy exposing per-request metrics on `:9091`
- [`nv-monitor`](https://github.com/wentbackward/nv-monitor) — Prometheus-format system/GPU metrics for NVIDIA hardware (works correctly on unified-memory platforms like DGX Spark)

Works standalone with any OpenAI-compatible backend that emits Prometheus metrics (vLLM does by default on `/metrics`).

---

## What you get

- **Prometheus** — 30-day TSDB retention by default, scrape configs for `llm-proxy`, `nv-monitor`, and vLLM
- **Grafana 11** — two provisioned dashboards:
  - *LLM Observability* — request latency, TTFT, token counts, error rates
  - *GPU & System Resources* — CPU / GPU / memory / temps / power across nodes
- **HTTPS via `tailscale serve`** — Grafana is bound to `127.0.0.1:3033` on the host and exposed on the tailnet with an auto-renewing Tailscale cert. No manual cert management, no public exposure.

---

## Prerequisites

- VPS or LAN host with Docker + Docker Compose
- Tailscale installed, authenticated, and with **HTTPS enabled** on the tailnet
- Scrape targets reachable from the host (typically other Tailscale nodes running `llm-proxy`, `nv-monitor`, or `vllm`)
- Root SSH access from your deploy machine to the host

---

## Quick start

### 1. Clone and configure

```bash
git clone https://github.com/wentbackward/llm-observability.git
cd llm-observability
cp .env.example .env
# edit .env — set GRAFANA_PASSWORD at minimum
```

### 2. Point `prometheus.yml` at your infrastructure

Edit `prometheus.yml` and change the `targets:` entries. The file ships with a `spark-01` example host; replace with your own (e.g. `gpu-host-1:9091`, `gpu-host-1:9011`, etc.).

### 3. Deploy

```bash
VPS=root@<your-host> ./deploy.sh
```

This rsyncs the repo to `/opt/llm-observability/` on the host, copies `.env`, and starts the stack. Prometheus binds only inside the Docker network; Grafana binds to `127.0.0.1:3033` on the host.

### 4. Enable HTTPS via Tailscale

```bash
VPS=root@<your-host> ./deploy.sh tailscale-serve
```

Now reachable at `https://<host>.<tailnet>.ts.net:3033`. Log in with `admin` + `GRAFANA_PASSWORD` from your `.env`. Change the password from the Grafana UI on first login.

---

## Adding a new target

1. Edit `prometheus.yml` — add the target under the appropriate `job_name` block. Use a `host:` label on the target if the dashboard's `host` template variable should pick it up automatically.
2. Redeploy: `./deploy.sh` — Prometheus reloads its config on container restart.

Grafana auto-reloads dashboard JSON every 30s (`updateIntervalSeconds` in the dashboard provisioner), so edits to files in `grafana/dashboards/` propagate without a restart.

---

## Migrating existing volume data

If you're moving from a previous Prometheus/Grafana deployment and want to keep the historical TSDB and dashboards, point at the existing Docker volumes via `.env`:

```ini
PROMETHEUS_VOLUME=oldproject_prometheus-data
GRAFANA_VOLUME=oldproject_grafana-data
```

Docker Compose will adopt the existing volumes instead of creating new ones. On first deploy, confirm with:

```bash
ssh root@<host> docker volume ls
```

---

## Layout

```
llm-observability/
├── compose.yml                         Prometheus + Grafana services
├── prometheus.yml                      Scrape configs — edit for your targets
├── .env.example                        Copy to .env and fill in
├── deploy.sh                           rsync + up / tailscale-serve
└── grafana/
    ├── provisioning/
    │   ├── datasources/prometheus.yml  Prometheus datasource (uid=prometheus)
    │   └── dashboards/dashboards.yml   Dashboard auto-discovery
    └── dashboards/
        ├── llm-overview.json           LLM request / latency / token metrics
        └── gpu-system.json             GPU + host resources
```

---

## Security notes

- Grafana is bound only to `127.0.0.1` — unreachable from any public or LAN interface
- HTTPS is provided by `tailscale serve`; only tailnet members can reach the UI
- Prometheus is not exposed on the host at all — internal Docker network only
- No authentication on Prometheus's scrape endpoint — access depends entirely on tailnet membership. Do not deploy this stack on a public-facing VPS without additional hardening.

---

## License

MIT.
