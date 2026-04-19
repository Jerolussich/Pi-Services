from flask import Flask, render_template, request, redirect, url_for, Response, jsonify
from flask_wtf.csrf import CSRFProtect
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
import os
import sqlite3
import subprocess
from datetime import date

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY") or os.urandom(32)
csrf = CSRFProtect(app)
limiter = Limiter(key_func=get_remote_address, app=app, default_limits=["60 per minute"], storage_uri="memory://")

DB_PATH       = "/app/exports/fitbit.db"
EXPORT_SCRIPT = "/app/export.py"
LOG_FILE      = "/app/data/fitbit-ui.log"
GRID_MONTHS   = 18

UI_USERNAME = os.environ.get("UI_USERNAME", "admin")
UI_PASSWORD = os.environ.get("UI_PASSWORD", "admin")

DATA_TABLES = ("actividad", "sueno", "heart_rate", "ejercicios")


def check_auth(username, password):
    return username == UI_USERNAME and password == UI_PASSWORD


@app.before_request
def require_auth():
    auth = request.authorization
    if not auth or not check_auth(auth.username, auth.password):
        return Response("Authentication required.", 401,
                        {"WWW-Authenticate": 'Basic realm="Fitbit Ingest"'})


def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def read_log():
    if not os.path.exists(LOG_FILE):
        return "No runs yet."
    with open(LOG_FILE) as f:
        return "".join(f.readlines()[-200:])


def month_list(n):
    today = date.today()
    y, m = today.year, today.month
    out = []
    for _ in range(n):
        out.append((y, m))
        m -= 1
        if m == 0:
            m = 12
            y -= 1
    return out


def collect_status(conn, months):
    counts = {ym: {t: 0 for t in DATA_TABLES} for ym in months}
    for tbl in DATA_TABLES:
        try:
            rows = conn.execute(
                f"SELECT strftime('%Y-%m', fecha) ym, COUNT(*) c FROM {tbl} GROUP BY ym"
            ).fetchall()
        except sqlite3.OperationalError:
            rows = []
        for r in rows:
            if not r["ym"]:
                continue
            y, m = int(r["ym"][:4]), int(r["ym"][5:7])
            if (y, m) in counts:
                counts[(y, m)][tbl] = r["c"]

    last_runs = {}
    try:
        rows = conn.execute("""
            SELECT year, month, started_at, finished_at, status, source
            FROM ingest_runs
            WHERE (year, month, started_at) IN (
                SELECT year, month, MAX(started_at)
                FROM ingest_runs GROUP BY year, month
            )
        """).fetchall()
        for r in rows:
            last_runs[(r["year"], r["month"])] = dict(r)
    except sqlite3.OperationalError:
        pass

    result = []
    for y, m in months:
        c = counts[(y, m)]
        non_zero = sum(1 for t in DATA_TABLES if c[t] > 0)
        if non_zero == 0:
            state = "empty"
        elif non_zero == len(DATA_TABLES):
            state = "full"
        else:
            state = "partial"
        result.append({
            "year": y, "month": m,
            "label": f"{y}-{m:02d}",
            "counts": c,
            "state": state,
            "last_run": last_runs.get((y, m)),
        })
    return result


def is_running_for(conn, year, month):
    try:
        row = conn.execute(
            "SELECT 1 FROM ingest_runs WHERE year=? AND month=? AND status='running' LIMIT 1",
            (year, month),
        ).fetchone()
        return row is not None
    except sqlite3.OperationalError:
        return False


def any_running(conn):
    try:
        row = conn.execute(
            "SELECT 1 FROM ingest_runs WHERE status='running' LIMIT 1"
        ).fetchone()
        return row is not None
    except sqlite3.OperationalError:
        return False


@app.route("/", methods=["GET"])
def index():
    months = month_list(GRID_MONTHS)
    conn = db()
    try:
        status = collect_status(conn, months)
        running = any_running(conn)
    finally:
        conn.close()

    default_ym = next((s["label"] for s in status if s["state"] != "full"), status[0]["label"])
    return render_template(
        "index.html",
        grid=status,
        default_ym=default_ym,
        running=running or request.args.get("running", "0") == "1",
        log=read_log(),
    )


@app.route("/months", methods=["GET"])
@csrf.exempt
@limiter.exempt
def months_json():
    months = month_list(GRID_MONTHS)
    conn = db()
    try:
        status = collect_status(conn, months)
        running = any_running(conn)
    finally:
        conn.close()
    return jsonify({"months": status, "running": running})


@app.route("/log", methods=["GET"])
@csrf.exempt
@limiter.exempt
def log_content():
    return jsonify({"log": read_log()})


@app.route("/ingest", methods=["POST"])
@limiter.limit("5 per minute")
def ingest():
    ym = (request.form.get("ym") or "").strip()
    try:
        year = int(ym[:4])
        month = int(ym[5:7])
        assert 1 <= month <= 12 and 2000 <= year <= 2100 and ym[4] == "-"
    except Exception:
        return redirect(url_for("index"))

    conn = db()
    try:
        if is_running_for(conn, year, month):
            return redirect(url_for("index", running=1))
    finally:
        conn.close()

    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    with open(LOG_FILE, "a") as log:
        log.write(f"\n--- {ym} manual run requested ---\n")
        log.flush()
        subprocess.Popen(
            ["python", EXPORT_SCRIPT, "--year", str(year), "--month", str(month), "--source", "manual"],
            stdout=log, stderr=log,
        )
    return redirect(url_for("index", running=1))
