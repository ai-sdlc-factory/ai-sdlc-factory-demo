#!/bin/sh
# Delivers app/ to the demo "production": build images tagged with this repository's commit, switch the containers over, check that
# they answer, and roll back by itself when they do not. Change something in app/, commit it, and run this.
#   ./deploy.sh              deliver the current commit (nothing happens when it is already running)
#   ./deploy.sh --force      deliver it even when it is already running (rebuilds)
#   ./deploy.sh --rollback   go back to the previous delivered version
# Every delivery is a line in deployments.log and a marker on the Grafana dashboard.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

mode=deploy
for argument in "$@"; do
    case "$argument" in
        --force) mode=force ;;
        --rollback) mode=rollback ;;
        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $argument (try --help)" >&2; exit 2 ;;
    esac
done

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[ -f .env ] || fail ".env is missing: run ./setup.sh first."
env_value() { sed -n "s/^$1=//p" .env | head -n 1; }
set_value() { if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s=%s\n' "$1" "$2" >> .env; fi; }

current=$(env_value WEATHER_VERSION)
api_port=$(env_value WEATHER_API_PORT); api_port=${api_port:-5080}
web_port=$(env_value WEATHER_WEB_PORT); web_port=${web_port:-8081}
grafana_port=$(env_value GRAFANA_PORT); grafana_port=${grafana_port:-3001}
log=deployments.log

record() { printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$log"; }

annotate() {
    # A marker on the Grafana dashboard; best effort, never a reason to fail a delivery.
    text=$1
    curl -fsS -m 5 -u "admin:$(env_value GRAFANA_ADMIN_PASSWORD)" -H 'Content-Type: application/json' \
        -d "{\"tags\":[\"deploy\"],\"text\":\"$text\"}" "http://127.0.0.1:$grafana_port/api/annotations" >/dev/null 2>&1 || true
}

answers() {
    tries=45
    while [ "$tries" -gt 0 ]; do
        if curl -fsS -o /dev/null -m 3 "http://127.0.0.1:$api_port/api/cities" 2>/dev/null \
            && curl -fsS -o /dev/null -m 3 "http://127.0.0.1:$web_port/healthz" 2>/dev/null; then return 0; fi
        tries=$((tries - 1)); sleep 2
    done
    return 1
}

switch_to() {
    WEATHER_VERSION=$1 docker compose up -d --no-build weather-api weather-web
}

if [ "$mode" = rollback ]; then
    previous=$(grep ' ok$' "$log" 2>/dev/null | awk '{print $2}' | awk -v cur="$current" '$0 != cur { last = $0 } END { print last }')
    [ -n "$previous" ] || fail "There is no earlier delivered version to go back to."
    say() { printf '%s\n' "$*"; }
    say "Rolling back from ${current:-unknown} to $previous"
    switch_to "$previous"
    if answers; then
        set_value WEATHER_VERSION "$previous"; record "$previous" ok; annotate "Rollback to $previous"
        say "Rolled back to $previous."
        exit 0
    fi
    record "$previous" failed
    fail "The previous version does not answer either. Look at: docker compose logs weather-api"
fi

# 1. The version is this repository's commit; uncommitted changes in app/ make it "<commit>-dirty" (rebuilt on every run).
if git rev-parse --git-dir >/dev/null 2>&1 && git rev-parse HEAD >/dev/null 2>&1; then
    sha=$(git rev-parse --short HEAD)
    message=$(git log -1 --format=%s | cut -c1-80 | tr -d '"\\')
    [ -z "$(git status --porcelain -- app)" ] || { sha="$sha-dirty"; message="$message (uncommitted changes in app/)"; }
else
    sha=local; message="app/ (not a git checkout)"
fi

if [ "$mode" = deploy ] && [ "$sha" = "$current" ] && [ "${sha%-dirty}" = "$sha" ] && docker compose ps --status running weather-api 2>/dev/null | grep -q weather-api; then
    echo "$sha is already running. Nothing to do (--force rebuilds)."
    exit 0
fi

# 2. Build the images for this commit, then switch the containers over.
echo "Delivering $sha: $message"
WEATHER_VERSION=$sha docker compose build weather-api weather-web
switch_to "$sha"

# 3. Check it, and go back by itself when it does not answer.
if answers; then
    set_value WEATHER_VERSION "$sha"
    record "$sha" ok
    annotate "Deployed $sha: $message"
    echo "Delivered $sha."
    exit 0
fi
record "$sha" failed
echo "$sha does not answer." >&2
previous=$(grep ' ok$' "$log" 2>/dev/null | awk '{print $2}' | tail -n 1)
if [ -n "$previous" ]; then
    echo "Going back to $previous" >&2
    switch_to "$previous"
    answers && { annotate "Delivery of $sha failed; back on $previous"; fail "Delivery of $sha failed; $previous is running again."; }
fi
fail "Delivery of $sha failed. See: docker compose logs weather-api"
