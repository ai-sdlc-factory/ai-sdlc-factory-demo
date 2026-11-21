#!/usr/bin/env python3
"""Prometheus metrics about this demo's containers, read from the Docker API (state, health, restarts, memory, CPU).

It replaces cAdvisor, which cannot see individual containers on every host (cgroup v2 under WSL2). It only lists and reads containers of the Compose
project it is told about, over the Docker socket, and writes nothing. Standard library only.
"""
import http.client
import json
import os
import socket
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SOCKET = os.environ.get("DOCKER_SOCKET", "/var/run/docker.sock")
PROJECT = os.environ.get("COMPOSE_PROJECT", "dev-foundry-demo")
PORT = int(os.environ.get("PORT", "9101"))

_previous_cpu = {}  # container id -> (wall seconds, total cpu nanoseconds)
_lock = threading.Lock()


class _Unix(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=5)
        self._path = path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(self._path)
        self.sock = sock


def _get(path):
    connection = _Unix(SOCKET)
    try:
        connection.request("GET", path)
        response = connection.getresponse()
        body = response.read()
        if response.status != 200:
            raise RuntimeError(f"Docker answered {response.status} for {path.split('?')[0]}")
        return json.loads(body)
    finally:
        connection.close()


def _label(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def collect():
    lines = []

    def gauge(name, help_text, samples):
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} gauge")
        for labels, value in samples:
            lines.append(f"{name}{{{labels}}} {value}")

    running, restarts, started, health, memory, limit, cpu = [], [], [], [], [], [], []
    filters = urllib.parse.quote(json.dumps({"label": [f"com.docker.compose.project={PROJECT}"]}))
    ok = 1
    try:
        for container in _get(f"/containers/json?all=true&filters={filters}"):
            service = container["Labels"].get("com.docker.compose.service", "unknown")
            labels = f'service="{_label(service)}"'
            info = _get(f"/containers/{container['Id']}/json")
            state = info["State"]
            is_running = 1 if state.get("Running") else 0
            running.append((labels, is_running))
            restarts.append((labels, info.get("RestartCount", 0)))
            health_state = state.get("Health", {}).get("Status")
            health.append((labels, {"healthy": 1, "unhealthy": 0, "starting": 2}.get(health_state, -1)))
            if is_running:
                try:
                    started_at = time.mktime(time.strptime(state["StartedAt"][:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
                    started.append((labels, int(started_at)))
                except (KeyError, ValueError):
                    pass
                stats = _get(f"/containers/{container['Id']}/stats?stream=false&one-shot=true")
                mem = stats.get("memory_stats", {})
                inactive = mem.get("stats", {}).get("inactive_file", mem.get("stats", {}).get("cache", 0))
                if "usage" in mem:
                    memory.append((labels, max(mem["usage"] - inactive, 0)))
                if mem.get("limit"):
                    limit.append((labels, mem["limit"]))
                total = stats.get("cpu_stats", {}).get("cpu_usage", {}).get("total_usage")
                if total is not None:
                    now = time.monotonic()
                    with _lock:
                        before = _previous_cpu.get(container["Id"])
                        _previous_cpu[container["Id"]] = (now, total)
                    if before and now > before[0] and total >= before[1]:
                        cpu.append((labels, round((total - before[1]) / 1e9 / (now - before[0]), 4)))
    except Exception as error:  # the exporter reports that it could not read, instead of failing the scrape
        ok = 0
        lines.append(f"# could not read Docker: {type(error).__name__}")

    gauge("demo_container_running", "1 when the container is running.", running)
    gauge("demo_container_restarts", "How many times Docker restarted the container by itself.", restarts)
    gauge("demo_container_health", "1 healthy, 0 unhealthy, 2 starting, -1 the container has no health check.", health)
    gauge("demo_container_started_timestamp_seconds", "When the running container started (Unix time).", started)
    gauge("demo_container_memory_bytes", "Memory in use, without the page cache.", memory)
    gauge("demo_container_memory_limit_bytes", "The container's memory limit.", limit)
    gauge("demo_container_cpu_cores", "CPU use in cores, averaged since the last scrape.", cpu)
    gauge("demo_container_exporter_ok", "1 when Docker could be read.", [("", ok)])
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            body, kind = b"ok\n", "text/plain"
        elif self.path == "/metrics":
            body, kind = collect().encode(), "text/plain; version=0.0.4"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # no access log: Prometheus asks every 15 seconds
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
