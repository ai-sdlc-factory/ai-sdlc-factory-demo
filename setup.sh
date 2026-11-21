#!/bin/sh
# Prepares and starts the demo "production": the weather application from the default branch of its repository, and its monitoring.
#   ./setup.sh                   first start; alerts are only logged (a dry run)
#   ./setup.sh --create-tickets  also let the alert intake open tickets in Forgejo (this starts the factory's incident workflow: it spends tokens)
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

say "1/6 Checking what is needed"
command -v docker >/dev/null 2>&1 || fail "Docker is not installed or not on the PATH."
docker compose version >/dev/null 2>&1 || fail "Docker Compose (the 'docker compose' command) is not available."
docker info >/dev/null 2>&1 || fail "Cannot talk to the Docker daemon. Is it running, and may you use it?"
for tool in git curl python3; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is needed."; done
[ -r ../../deploy/.env ] || fail "deploy/.env is missing: set up the factory first (docs/getting-started.md). The demo takes its source from the factory's Forgejo."

env_value() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1; }
random_secret() { head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c "$1"; }

say "2/6 Writing demo/.env and the secrets (kept if they already exist)"
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
# The factory's git hosts are listed in FACTORY_HOSTS (deploy/.env). The demo's scripts fetch the source from the first Forgejo with its token; the alert intake gets the
# hosts as its own list (ALERT_INTAKE_HOSTS: name, type, address, no webhook secrets), without the tokens too while it only does a dry run (it is given them only when tickets are really wanted).
[ "$create_tickets" = true ] && set_value ALERT_INTAKE_DRY_RUN false
[ "$(env_value ALERT_INTAKE_DRY_RUN .env)" = false ] || set_value ALERT_INTAKE_DRY_RUN true
with_tokens=false
[ "$(env_value ALERT_INTAKE_DRY_RUN .env)" = false ] && with_tokens=true
python3 - ../../deploy/.env "$with_tokens" > .hosts.tmp <<'PY' || fail "FACTORY_HOSTS is not set in deploy/.env, or has no Forgejo with a token: the scripts need it to fetch the source."
import json, sys
text = ""
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("FACTORY_HOSTS="):
        text = line.partition("=")[2].strip().strip("'")
hosts = json.loads(text)
forgejo = next(h for h in hosts if h.get("type", "forgejo") == "forgejo" and h.get("token"))
with_tokens = sys.argv[2] == "true"
intake = [{"name": h["name"], "type": h.get("type", "forgejo"), "url": h["url"]} | ({"token": h.get("token", "")} if with_tokens else {}) for h in hosts]
print(forgejo["token"])
print(json.dumps(intake, separators=(",", ":")))
PY
set_value FORGEJO_BOT_TOKEN "$(sed -n 1p .hosts.tmp)"
set_value ALERT_INTAKE_HOSTS "$(sed -n 2p .hosts.tmp)"
rm -f .hosts.tmp
# Alertmanager reads the intake's token from a file, so it is never written into a config.
umask 077
printf '%s' "$(env_value ALERT_INTAKE_TOKEN .env)" > secrets/intake-token
chmod 644 secrets/intake-token
umask 022

say "3/6 Checking the factory's network (the intake reaches Forgejo through it)"
network=$(env_value FACTORY_FORGE_NETWORK .env)
network=${network:-dev-foundry_forge}
docker network inspect "$network" >/dev/null 2>&1 || fail "The Docker network $network does not exist. Start the factory first: cd ../../deploy && docker compose up -d"

say "4/6 Starting the monitoring stack and the alert intake"
docker compose up -d --build prometheus alertmanager blackbox container-stats loki promtail grafana alert-intake

say "5/6 Delivering the application (building it from the default branch)"
./deploy.sh --force

say "6/6 Waiting for everything to answer"
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
wait_for "weather web" "http://127.0.0.1:$(env_value WEATHER_WEB_PORT .env)/healthz" || failed=1
wait_for "weather API" "http://127.0.0.1:$(env_value WEATHER_API_PORT .env)/api/cities" || failed=1
wait_for "Prometheus" "http://127.0.0.1:$(env_value PROMETHEUS_PORT .env)/-/ready" || failed=1
wait_for "Alertmanager" "http://127.0.0.1:$(env_value ALERTMANAGER_PORT .env)/-/ready" || failed=1
wait_for "Grafana" "http://127.0.0.1:$(env_value GRAFANA_PORT .env)/api/health" || failed=1
[ "$failed" = 0 ] || fail "Something did not come up. See: docker compose logs <service>"

say ""
say "The demo is running."
say "  Application  http://localhost:$(env_value WEATHER_WEB_PORT .env)   (API http://localhost:$(env_value WEATHER_API_PORT .env)/api/cities)"
say "  Grafana      http://localhost:$(env_value GRAFANA_PORT .env)   user admin, password in demo/.env (GRAFANA_ADMIN_PASSWORD)"
say "  Prometheus   http://localhost:$(env_value PROMETHEUS_PORT .env)   Alertmanager http://localhost:$(env_value ALERTMANAGER_PORT .env)"
if [ "$(env_value ALERT_INTAKE_DRY_RUN .env)" = false ]; then
    say "  Alerts       open real tickets in $(env_value DEMO_REPO .env) (rate limited); the factory's incident workflow starts on them"
else
    say "  Alerts       only logged (dry run): docker compose logs -f alert-intake    to open real tickets: ./setup.sh --create-tickets"
fi
say "Try it:  ./simulate.sh api-down   then watch Grafana and the intake log.   Deliver new code:  ./deploy.sh"
