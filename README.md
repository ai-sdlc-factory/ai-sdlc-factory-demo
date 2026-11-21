# The demo "production" and its monitoring

A place to run the weather application **from the default branch of its repository**, the way a delivery pipeline would, with monitoring around it that **opens tickets when something breaks**. Everything is local Docker. It is where the factory's incident side gets something real to watch.

![Monitoring and alerts](../../docs/images/monitoring.svg)

| Part | What it is | Address (localhost only) |
| --- | --- | --- |
| weather-web, weather-api | the application, built from the repository's default branch | http://localhost:8081, API http://localhost:5080/api/cities |
| Prometheus | metrics and alert rules; probes the API and the web page from outside, like a user | http://localhost:9090 |
| container-stats | state, health, restarts, memory and CPU of every container, read from the Docker API (`exporter/container_stats.py`) | (inside the stack) |
| Loki + Promtail | the containers' logs, searchable, with alert rules on log lines | (inside the stack) |
| Alertmanager | groups alerts and sends them on | http://localhost:9093 |
| Grafana | two dashboards: **Overview** (the home page) and **Weather service** (details) | http://localhost:3001 (user `admin`, password in `demo/.env`) |
| alert-intake | turns an alert into a ticket on a git host: [its README](../alert-intake/README.md) | (inside the stack) |

## Start it

The factory must be running first (the demo fetches the source from its Forgejo and reaches Forgejo through its Docker network).

```sh
cd companions/demo
./setup.sh                    # first start: prepares everything, alerts are only LOGGED (dry run)
./setup.sh --create-tickets   # later: let alerts open real tickets
```

`setup.sh` checks Docker, writes `demo/.env` and `demo/secrets/` (random passwords and tokens, kept on re-runs, never committed), builds and starts the monitoring, delivers the application with `deploy.sh`, and waits until everything answers. The first run downloads about 1.5 GB of images and builds the application, which takes a few minutes.

**Real tickets spend tokens:** a ticket labelled `incident` starts the factory's incident workflow, which uses the model. That is why a dry run is the default. To go back to a dry run, set `ALERT_INTAKE_DRY_RUN=true` in `demo/.env` and run `docker compose up -d alert-intake`.

## See what is happening

| Where | What you see |
| --- | --- |
| **Grafana → Overview** (the home page) | at the top: is the API up, is the web page up, how many alerts fire, whether a monitoring part is down, whether alerts open real tickets or are only logged (dry run), how many alerts were handled in 24 hours. Below: the active alerts, a timeline of when each alert was pending or firing, what the alert intake did with them (a chart and its decision log), the deliveries, every container (running, for how long, restarts, memory, CPU) and the logs |
| **Grafana → Weather service** | the details of the application: response time, memory, CPU, error lines per minute, logs. Orange markers are deliveries |
| `./status.sh` | the same in one screen of text: containers, probes, alerts, what the intake did and its last decisions, the deliveries, and the tickets opened from alerts |
| Prometheus → Alerts | every rule and its state: inactive, pending (waiting out its `for` time) or firing: http://localhost:9090/alerts |
| Alertmanager | the alerts that were sent on, and silences: http://localhost:9093 |
| `docker compose logs -f alert-intake` | every decision of the intake as it happens |
| **Forgejo** | the tickets themselves (label `incident`, title `[alert] ...`), and then the factory's incident workflow on them; follow it in the [Temporal UI](http://localhost:8080) |

The monitoring watches itself: a part that stops answering, an intake that cannot reach Forgejo, one that holds tickets back, and one that refuses notifications each have an alert (`service: monitoring`). Those alerts open **no** tickets; you see them in Alertmanager and on the Overview.

## Deliver code to "production"

```sh
./deploy.sh              # fetch the default branch, build images tagged with the commit, switch over, check, roll back by itself if it does not answer
./deploy.sh --force      # deliver it even when it is already running
./deploy.sh --rollback   # back to the previous delivered version
```

Each delivery is a line in `demo/deployments.log` and an orange marker on the Grafana dashboard, so a change in the graphs can be tied to a delivery. This is a small stand-in for a pipeline: the next step is to let a push to the default branch (a merged pull request) trigger it.

## Break it on purpose

```sh
./simulate.sh api-down    # stop the API: WeatherApiDown fires after about a minute
./simulate.sh errors      # write error lines to the API log: WeatherApiErrorLogs fires
./status.sh              # one screen: containers, alerts, what the intake did, deliveries, tickets
./simulate.sh restore     # start everything again; the alerts resolve and the ticket gets a comment
docker compose logs -f alert-intake
```

The path of an alert: Prometheus (or Loki) evaluates a rule, the alert stays **pending** for its `for` time (1 minute for the "down" alerts), Alertmanager waits 30 seconds to group alerts, then posts to the intake. In a dry run the log says `Dry run: would open a ticket in valters/weather titled [alert] WeatherApiDown: ...`; otherwise a ticket appears.

## The alerts

| Alert | Fires when | Source |
| --- | --- | --- |
| WeatherApiDown | `GET /api/cities` fails for 1 minute | Prometheus, blackbox probe |
| WeatherWebDown | the web page's health check fails for 1 minute | Prometheus, blackbox probe |
| WeatherApiSlow | the API takes more than 1 second for 3 minutes | Prometheus, blackbox probe |
| WeatherApiMemoryHigh | the API container uses more than 400 MB for 5 minutes | Prometheus, container-stats |
| WeatherApiRestarting | Docker restarted the API container more than twice in 15 minutes | Prometheus, container-stats |
| WeatherApiUnhealthy | Docker's health check of the API container fails for 2 minutes | Prometheus, container-stats |
| WeatherApiErrorLogs | more than 5 error lines in the API log within 5 minutes | Loki rule |

The rules are in `prometheus/rules/weather.yml` and `loki/rules/fake/weather.yml`; the alerts about the monitoring itself are in `prometheus/rules/monitoring.yml`. Which alert goes to which repository is `intake-routes/mapping.json`.

## Stop it

```sh
./down.sh           # stop; data is kept
./down.sh --purge   # also remove the data and the downloaded source
```

## What to know

- **Local only.** Every port is bound to 127.0.0.1. Promtail and container-stats read the Docker socket, which is root on the host, so this stack is for your own machine, not a server.
- **It is not the factory's sandbox.** The application runs here with normal networking. The factory's agents never get access to it; they see only what a ticket says.
- **The frontend's API address is built in** (`http://localhost:5080`), so the application is reachable from your browser on this machine only.
- **Configuration** (ports, repository, branch) is in `demo/.env`; `.env.example` lists the keys. The alert intake's settings are in [the configuration reference](../alert-intake/README.md#settings).

## If something does not work

| Symptom | Likely cause and fix |
| --- | --- |
| `setup.sh` stops with "error getting credentials" while pulling images | Docker's credential helper failed under many parallel pulls (seen under WSL2). Pull the images one at a time (`docker pull prom/alertmanager:v0.28.1`, and so on for the images in `compose.yaml`), then run `./setup.sh` again |
| "The Docker network dev-foundry_forge does not exist" | the factory is not running: `cd ../../infra && docker compose up -d` |
| an alert fires but no ticket appears | the intake is in dry run (the Overview says so; `./status.sh` too), or the alert matches no route in `intake-routes/mapping.json`, or the hourly limit is reached: `docker compose logs alert-intake` says which |
| the intake log shows "unauthorized" or Prometheus shows `AlertIntakeRefusingNotifications` | Alertmanager and the intake do not share the token: run `./setup.sh` again (it rewrites `secrets/intake-token` from `.env`) and `docker compose up -d alertmanager alert-intake` |
| a panel on a dashboard is empty | give it a minute after a restart; then check Prometheus → Status → Targets: every target must be up |
| `deploy.sh` says a version does not answer | it rolled back by itself; look at `docker compose logs weather-api` for the failed version |
