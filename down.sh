#!/bin/sh
# Stops the demo. --purge also removes its data (the weather database, metrics, logs and dashboards' state) and the downloaded source.
set -eu
cd "$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = --purge ]; then
    docker compose down -v
    rm -rf src deployments.log
    echo "Stopped and removed the demo's data. demo/.env and demo/secrets are kept."
else
    docker compose down
    echo "Stopped. Data is kept; ./setup.sh starts it again (--purge removes it)."
fi
