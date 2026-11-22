#!/bin/sh
# Breaks the demo on purpose, so you can watch monitoring notice it and the alert intake react.
#   ./simulate.sh api-down    stop the API                (ShopApiDown fires after about a minute)
#   ./simulate.sh web-down    stop the web page           (ShopWebDown)
#   ./simulate.sh errors      write error lines into the API log (ShopApiErrorLogs, when there are more than 5 in 5 minutes)
#   ./simulate.sh restore     start everything again
#   ./simulate.sh status      the same as ./status.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
[ -f .env ] || { echo "Run ./setup.sh first." >&2; exit 1; }
env_value() { sed -n "s/^$1=//p" .env | head -n 1; }
prom="http://127.0.0.1:$(env_value PROMETHEUS_PORT)"
alerts="http://127.0.0.1:$(env_value ALERTMANAGER_PORT)"

case "${1:-}" in
    api-down)
        docker compose stop shop-api
        echo "The API is stopped. Within about a minute Prometheus raises ShopApiDown, and about 30 seconds later Alertmanager sends it to the intake."
        echo "Watch:  ./simulate.sh status      docker compose logs -f alert-intake"
        ;;
    web-down)
        docker compose stop shop-web
        echo "The web page is stopped. Expect ShopWebDown in about a minute."
        ;;
    errors)
        i=1
        while [ "$i" -le 12 ]; do
            docker compose exec -T shop-api sh -c "echo 'ERROR simulated failure $i: something broke' > /proc/1/fd/1"
            i=$((i + 1))
        done
        echo "Wrote 12 error lines to the API log. Loki's rule ShopApiErrorLogs fires when it sees more than 5 within 5 minutes."
        ;;
    restore)
        docker compose up -d shop-api shop-web
        echo "Started. The alerts resolve by themselves; the intake then comments on their tickets (or logs it, in a dry run)."
        ;;
    status)
        ./status.sh
        ;;
    *)
        sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
