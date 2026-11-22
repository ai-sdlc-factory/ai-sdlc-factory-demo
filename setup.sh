#!/bin/sh
# Prepares and starts the demo "production": the shop application (in app/) and its monitoring.
#   ./setup.sh                   first start; alerts are only logged (a dry run)
#   ./setup.sh --create-tickets  also let the alert intake open tickets on your git host (if a dev-foundry factory serves that repository, the ticket starts its incident workflow: it spends tokens)
# Safe to run again: it keeps the secrets it generated and only changes what you ask for.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

create_tickets=false
for argument in "$@"; do
    case "$argument" in
        --create-tickets) create_tickets=true ;;
        -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $argument (try --help)" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

say "1/5 Checking what is needed"
command -v docker >/dev/null 2>&1 || fail "Docker is not installed or not on the PATH."
docker compose version >/dev/null 2>&1 || fail "Docker Compose (the 'docker compose' command) is not available."
docker info >/dev/null 2>&1 || fail "Cannot talk to the Docker daemon. Is it running, and may you use it?"
for tool in curl python3; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is needed."; done
[ -d app/api ] || fail "app/ is missing the shop application. See README.md."

env_value() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1; }
random_secret() { head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c "$1"; }

say "2/5 Writing .env and the secrets (kept if they already exist)"
mkdir -p secrets
[ -f .env ] || cp .env.example .env
chmod 600 .env
set_value() {
    # Replaces KEY=... in .env, or adds it. Values are plain tokens, so no quoting is needed.
    escaped=$(printf '%s' "$2" | sed 's/[&|\\]/\\&/g')
    if grep -q "^$1=" .env; then
        sed -i "s|^$1=.*|$1=$escaped|" .env
    else
        printf '%s=%s\n' "$1" "$2" >> .env
    fi
}
[ -n "$(env_value GRAFANA_ADMIN_PASSWORD .env)" ] || set_value GRAFANA_ADMIN_PASSWORD "$(random_secret 24)"
[ -n "$(env_value ALERT_INTAKE_TOKEN .env)" ] || set_value ALERT_INTAKE_TOKEN "$(random_secret 40)"
# Where tickets go: DEMO_GIT_TYPE (forgejo or github), DEMO_GIT_URL, DEMO_REPO (owner/name) and, only for real tickets, DEMO_GIT_TOKEN.
# The alert intake gets them as its own settings: the host list (ALERT_INTAKE_HOSTS, with the token only when tickets are really wanted) and the
# route table (generated/mapping.json, which sends the shop alerts to DEMO_REPO).
[ "$create_tickets" = true ] && set_value ALERT_INTAKE_DRY_RUN false
[ "$(env_value ALERT_INTAKE_DRY_RUN .env)" = false ] || set_value ALERT_INTAKE_DRY_RUN true
with_tokens=false
[ "$(env_value ALERT_INTAKE_DRY_RUN .env)" = false ] && with_tokens=true
if [ "$with_tokens" = true ]; then
    [ -n "$(env_value DEMO_GIT_TOKEN .env)" ] || fail "Real tickets need DEMO_GIT_TOKEN in .env: a token that may create issues in $(env_value DEMO_REPO .env) (see README.md)."
    case "$(env_value DEMO_REPO .env)" in */*) ;; *) fail "Set DEMO_REPO in .env to owner/name of the repository that receives the tickets." ;; esac
fi
mkdir -p generated
python3 - .env "$with_tokens" > generated/hosts.tmp <<'PY'
import json, sys
values = {}
for line in open(sys.argv[1], encoding="utf-8"):
    key, _, value = line.rstrip("\n").partition("=")
    values[key] = value
kind = values.get("DEMO_GIT_TYPE") or "forgejo"
url = values.get("DEMO_GIT_URL") or ("https://github.com" if kind == "github" else "http://host.docker.internal:3000")
host = {"name": kind, "type": kind, "url": url}
if sys.argv[2] == "true":
    host["token"] = values.get("DEMO_GIT_TOKEN", "")
repo = values.get("DEMO_REPO") or "owner/shop"
mapping = {"routes": [{
    "match": {"service": "shop"},
    "repository": repo,
    "labels": ["incident"],
    "evidence": [
        {"title": "Recent error lines of the API", "query": '{compose_service="shop-api"} |~ "(?i)(error|exception|fatal)"'},
        {"title": "Last lines of the API log", "query": '{compose_service="shop-api"}'},
    ]}]}
print(json.dumps([host], separators=(",", ":")))
print(json.dumps(mapping, indent=2))
PY
set_value ALERT_INTAKE_HOSTS "$(sed -n 1p generated/hosts.tmp)"
sed -n '2,$p' generated/hosts.tmp > generated/mapping.json
rm -f generated/hosts.tmp
# Alertmanager reads the intake's token from a file, so it is never written into a config.
umask 077
printf '%s' "$(env_value ALERT_INTAKE_TOKEN .env)" > secrets/intake-token
chmod 644 secrets/intake-token
umask 022

say "3/5 Starting the monitoring stack and the alert intake"
docker compose up -d --build prometheus alertmanager blackbox container-stats loki promtail grafana alert-intake

say "4/5 Delivering the application (building it from app/)"
./deploy.sh --force

say "5/5 Waiting for everything to answer"
wait_for() {
    # wait_for NAME URL [seconds]
    tries=${3:-60}
    while [ "$tries" -gt 0 ]; do
        if curl -fsS -o /dev/null -m 3 "$2" 2>/dev/null; then say "  ok   $1"; return 0; fi
        tries=$((tries - 1)); sleep 2
    done
    say "  FAIL $1 ($2)"; return 1
}
failed=0
wait_for "shop web" "http://127.0.0.1:$(env_value SHOP_WEB_PORT .env)/healthz" || failed=1
wait_for "shop API" "http://127.0.0.1:$(env_value SHOP_API_PORT .env)/api/products" || failed=1
wait_for "Prometheus" "http://127.0.0.1:$(env_value PROMETHEUS_PORT .env)/-/ready" || failed=1
wait_for "Alertmanager" "http://127.0.0.1:$(env_value ALERTMANAGER_PORT .env)/-/ready" || failed=1
wait_for "Grafana" "http://127.0.0.1:$(env_value GRAFANA_PORT .env)/api/health" || failed=1
[ "$failed" = 0 ] || fail "Something did not come up. See: docker compose logs <service>"

say ""
say "The demo is running."
say "  Application  http://localhost:$(env_value SHOP_WEB_PORT .env)   (API http://localhost:$(env_value SHOP_API_PORT .env)/api/products)"
say "  Grafana      http://localhost:$(env_value GRAFANA_PORT .env)   user admin, password in .env (GRAFANA_ADMIN_PASSWORD)"
say "  Prometheus   http://localhost:$(env_value PROMETHEUS_PORT .env)   Alertmanager http://localhost:$(env_value ALERTMANAGER_PORT .env)"
if [ "$(env_value ALERT_INTAKE_DRY_RUN .env)" = false ]; then
    say "  Alerts       open real tickets in $(env_value DEMO_REPO .env) (rate limited)"
else
    say "  Alerts       only logged (dry run): docker compose logs -f alert-intake    to open real tickets: ./setup.sh --create-tickets"
fi
say "Try it:  ./simulate.sh api-down   then watch Grafana and the intake log.   Deliver new code:  ./deploy.sh"
