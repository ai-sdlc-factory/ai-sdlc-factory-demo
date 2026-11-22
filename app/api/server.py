"""A tiny shop API for the demo: products in SQLite, orders in memory-light rows. Standard library only.

GET  /api/products        the catalogue
GET  /api/products/<id>   one product (404 when unknown)
POST /api/orders          {"product_id": 1, "quantity": 2} -> 201 with the order
GET  /api/boom            always fails with a 500 and an ERROR line: a way to trigger the error-log alert by hand
Every request is one log line on stdout; failures are ERROR lines (Loki's rule counts them).
"""
import json
import os
import sqlite3
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DB_PATH = os.environ.get("DB_PATH", "/data/shop.db")
PORT = int(os.environ.get("PORT", "5080"))
lock = threading.Lock()

PRODUCTS = [
    (1, "Espresso beans, 1 kg", 18.50),
    (2, "Pour-over kettle", 42.00),
    (3, "Ceramic mug", 9.90),
    (4, "Hand grinder", 35.00),
]


def connect():
    return sqlite3.connect(DB_PATH, timeout=5)


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    with connect() as db:
        db.execute("create table if not exists products (id integer primary key, name text not null, price real not null)")
        db.execute("create table if not exists orders (id integer primary key autoincrement, product_id integer not null, quantity integer not null)")
        if db.execute("select count(*) from products").fetchone()[0] == 0:
            db.executemany("insert into products values (?, ?, ?)", PRODUCTS)


def log(level, message):
    print(f"{level} {message}", flush=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "shop-api"

    def log_message(self, format, *args):  # replaced by our own lines
        pass

    def send(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        log("INFO" if status < 500 else "ERROR", f"{self.command} {self.path} -> {status}")

    def do_GET(self):
        try:
            if self.path == "/api/products":
                with connect() as db:
                    rows = db.execute("select id, name, price from products order by id").fetchall()
                self.send(200, [{"id": i, "name": n, "price": p} for i, n, p in rows])
            elif self.path.startswith("/api/products/"):
                with connect() as db:
                    row = db.execute("select id, name, price from products where id = ?", (self.path.rsplit("/", 1)[1],)).fetchone()
                self.send(200, {"id": row[0], "name": row[1], "price": row[2]}) if row else self.send(404, {"error": "no such product"})
            elif self.path == "/api/boom":
                raise RuntimeError("simulated failure on /api/boom")
            else:
                self.send(404, {"error": "not found"})
        except Exception as error:  # a failure is an ERROR line and a 500, never a crash
            log("ERROR", f"{self.command} {self.path} failed: {error}")
            self.send(500, {"error": "internal error"})

    def do_POST(self):
        try:
            if self.path != "/api/orders":
                return self.send(404, {"error": "not found"})
            length = int(self.headers.get("Content-Length", "0"))
            order = json.loads(self.rfile.read(min(length, 4096)) or b"{}")
            product, quantity = int(order["product_id"]), int(order["quantity"])
            if not 1 <= quantity <= 100:
                return self.send(400, {"error": "quantity must be 1 to 100"})
            with lock, connect() as db:
                if not db.execute("select 1 from products where id = ?", (product,)).fetchone():
                    return self.send(404, {"error": "no such product"})
                cursor = db.execute("insert into orders (product_id, quantity) values (?, ?)", (product, quantity))
            self.send(201, {"id": cursor.lastrowid, "product_id": product, "quantity": quantity})
        except (KeyError, ValueError, TypeError):
            self.send(400, {"error": "expected {\"product_id\": n, \"quantity\": n}"})
        except Exception as error:
            log("ERROR", f"{self.command} {self.path} failed: {error}")
            self.send(500, {"error": "internal error"})


if __name__ == "__main__":
    init_db()
    log("INFO", f"shop-api listening on {PORT}")
    try:
        ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
