# Working on the AI SDLC Factory demo

A small "production" (a shop in `app/`: Python API with SQLite, static page behind nginx) with monitoring around it that opens a ticket when something breaks. Runs locally in Docker only. Read `README.md` first (start, dry run vs real tickets, alerts table, troubleshooting).

## Layout
- `app/api`, `app/web`: the application being "delivered"
- `compose.yaml`: the whole stack (Prometheus, Alertmanager, Grafana, Loki, Promtail, blackbox, container-stats, alert-intake, shop)
- `prometheus/rules/` (`shop.yml`, `monitoring.yml`), `loki/rules/fake/shop.yml`: alert rules. `alertmanager/`, `blackbox/`, `promtail/`, `grafana/` (dashboards), `exporter/container_stats.py`
- Scripts: `setup.sh` (first start, writes `.env`, `secrets/`, `generated/`), `deploy.sh` (deliver, check, auto-rollback; logs to `deployments.log`), `simulate.sh` (break it on purpose), `status.sh`, `down.sh`
- `.factory/project.json`: factory settings for this repository
- `../ai-sdlc-factory-alert-intake` must be checked out next to this folder (or set `ALERT_INTAKE_SOURCE` in `.env`)

## Commands
- Start: `./setup.sh` (dry run: alerts only logged). Real tickets: `./setup.sh --create-tickets` (needs git host settings in `.env`)
- Deliver a change in `app/`: commit, then `./deploy.sh` (`--force`, `--rollback`)
- Try an alert: `./simulate.sh api-down | errors | restore`, then `./status.sh`
- Stop: `./down.sh` (`--purge` removes data)

## Rules
- **Dry run is the default and must stay so.** A real ticket labelled `incident` can start a factory run that spends model tokens. Do not switch it off or run `--create-tickets` without the owner's say.
- **Never read, print or commit `.env`, `secrets/` or `generated/`.** Change `.env.example` for new keys.
- Every port stays bound to 127.0.0.1. Promtail and container-stats read the Docker socket (root on the host): do not widen their access or expose the stack.
- A new alert needs a rule file entry, a row in the README alerts table, and a route in the generated mapping if it should open tickets. Alerts about the monitoring itself carry `service: monitoring` and open no tickets.
- `deploy.sh` tags images with the commit (`<commit>-dirty` for uncommitted changes); do not bypass its health check and rollback.
- **Committing:** only when asked, one logical change per commit. Keep `deployments.log`, `secrets/`, `generated/` and `.env` out of git.
