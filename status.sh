#!/bin/sh
# One screen of "what is happening": the containers, the application, the alerts, what the alert intake did, the deliveries and the tickets.
set -eu
cd "$(cd "$(dirname "$0")" && pwd)"
[ -f .env ] || { echo "Run ./setup.sh first." >&2; exit 1; }
env_value() { sed -n "s/^$1=//p" .env | head -n 1; }
prom="http://127.0.0.1:$(env_value PROMETHEUS_PORT)"
alerts="http://127.0.0.1:$(env_value ALERTMANAGER_PORT)"
api="http://127.0.0.1:$(env_value WEATHER_API_PORT)/api/cities"
web="http://127.0.0.1:$(env_value WEATHER_WEB_PORT)/healthz"
grafana="http://localhost:$(env_value GRAFANA_PORT)"
have_python=true; command -v python3 >/dev/null 2>&1 || have_python=false

heading() { printf '\n== %s\n' "$1"; }
probe() { if curl -fsS -o /dev/null -m 3 "$2" 2>/dev/null; then printf '  %-22s up\n' "$1"; else printf '  %-22s DOWN\n' "$1"; fi; }
json() {
    # json URL PYTHON-BODY : fetches JSON into d and runs the body; says so when it cannot.
    [ "$have_python" = true ] || { echo "  (python3 is needed to show this)"; return 0; }
    curl -fsS -m 5 "$1" 2>/dev/null | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print('  (not reachable)'); sys.exit(0)
$2" || true
}

heading "Containers"
docker compose ps --format '  {{.Service}}\t{{.Status}}' | sort

heading "The application"
probe "API  (GET /api/cities)" "$api"
probe "Web  (/healthz)" "$web"
printf '  version delivered      %s\n' "$(env_value WEATHER_VERSION)"

heading "Alerts in Prometheus (pending = waiting out its 'for' time)"
json "$prom/api/v1/alerts" "
a=d['data']['alerts']
print('  none' if not a else '')
for x in a: print('  %-8s %-34s %s' % (x['state'], x['labels'].get('alertname'), x['labels'].get('service','')))"

heading "Monitoring parts that do not answer"
json "$prom/api/v1/query?query=up%20%3D%3D%200" "
r=d['data']['result']
print('  none' if not r else '')
for x in r: print('  DOWN', x['metric'].get('job'), x['metric'].get('instance'))"

heading "What the alert intake did (since it started)"
if docker compose exec -T prometheus wget -qO- http://alert-intake:8000/metrics 2>/dev/null | grep -E '^alert_intake_(outcomes|rejected)_total|^alert_intake_(dry_run|notifications_total)' | sed 's/^/  /'; then :; else echo "  (not reachable)"; fi
echo "  last decisions:"
docker compose logs --no-log-prefix --tail 200 alert-intake 2>/dev/null | grep -E "Dry run|Opened ticket|no route|limit of|failed" | tail -5 | sed 's/^ */    /' | cut -c1-170 || true

heading "Deliveries (newest last)"
if [ -f deployments.log ]; then tail -n 5 deployments.log | sed 's/^/  /'; else echo "  none yet"; fi

heading "Tickets opened from alerts"
if [ "$(env_value ALERT_INTAKE_DRY_RUN)" = true ]; then
    echo "  dry run: no tickets are opened. ./setup.sh --create-tickets turns that on."
elif [ "$have_python" = true ]; then
    repo=$(env_value DEMO_REPO); kind=$(env_value DEMO_GIT_TYPE); kind=${kind:-forgejo}
    url=$(env_value DEMO_GIT_URL | sed 's#host.docker.internal#localhost#')
    if [ "$kind" = github ]; then
        endpoint="https://api.github.com/repos/$repo/issues?state=all&per_page=50"; auth="Authorization: Bearer $(env_value DEMO_GIT_TOKEN)"
    else
        endpoint="${url:-http://localhost:3000}/api/v1/repos/$repo/issues?state=all&type=issues&limit=50&q=%5Balert%5D"; auth="Authorization: token $(env_value DEMO_GIT_TOKEN)"
    fi
    curl -fsS -m 5 -H "$auth" "$endpoint" 2>/dev/null | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print('  (git host not reachable)'); sys.exit(0)
d=[i for i in d if i['title'].startswith('[alert]') and 'pull_request' not in i]
print('  none' if not d else '')
for i in d[:8]: print('  #%-4s %-6s %s' % (i['number'], i['state'], i['title'][:90]))" || true
fi

printf '\nWatch it live:  Grafana %s (Overview is the home page)   Prometheus %s/alerts   Alertmanager %s\n' "$grafana" "$prom" "$alerts"
