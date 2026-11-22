#!/bin/sh
# Stops the demo. --purge also removes its data (the shop database, metrics, logs and dashboards' state).
set -eu
cd "$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = --purge ]; then
    docker compose down -v
    rm -rf generated deployments.log
    echo "Stopped and removed the demo's data. The .env file and secrets/ are kept."
else
    docker compose down
    echo "Stopped. Data is kept; ./setup.sh starts it again (--purge removes it)."
fi
