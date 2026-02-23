from flask import Flask, render_template, request, redirect, url_for, Response, jsonify
from flask_wtf.csrf import CSRFProtect
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
import subprocess
import sqlite3
import json
import os

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY") or os.urandom(32)
csrf = CSRFProtect(app)
limiter = Limiter(key_func=get_remote_address, app=app, default_limits=["60 per minute"], storage_uri="memory://")

DB_PATH     = "/app/data/finance.db"
LOG_FILE    = "/app/data/tracker.log"
CONFIG_PATH = "/app/data/config.json"
PAUSE_FILE  = "/app/data/paused"

UI_USERNAME = os.environ.get("UI_USERNAME", "admin")
UI_PASSWORD = os.environ.get("UI_PASSWORD", "admin")

@app.before_request
def require_auth():
    auth = request.authorization
    if not auth or auth.username != UI_USERNAME or auth.password != UI_PASSWORD:
        return Response("Authentication required.", 401,
                        {"WWW-Authenticate": 'Basic realm="Finance Tracker"'})

def get_db():
    if not os.path.exists(DB_PATH):
        return None
    return sqlite3.connect(DB_PATH)

def read_log():
    if not os.path.exists(LOG_FILE):
        return "No runs yet."
    with open(LOG_FILE) as f:
        return "".join(f.readlines()[-100:])

def is_paused():
    return os.path.exists(PAUSE_FILE)

def load_config():
    if not os.path.exists(CONFIG_PATH):
        return {}
    with open(CONFIG_PATH) as f:
        return json.load(f)

def save_config(data):
    with open(CONFIG_PATH, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

def get_stats():
    conn = get_db()
    if not conn:
        return {}
    from datetime import datetime
    now        = datetime.now()
    this_month = now.strftime("%Y-%m")
    monthly_total = conn.execute("""
        SELECT COALESCE(SUM(amount), 0), currency FROM transactions
        WHERE strftime('%Y-%m', date) = ? AND currency = 'UYU'
    """, (this_month,)).fetchone()
    total_count = conn.execute("SELECT COUNT(*) FROM transactions").fetchone()[0]
    by_category = conn.execute("""
        SELECT category, ROUND(SUM(amount), 2) as total FROM transactions
        WHERE currency = 'UYU'
        GROUP BY category ORDER BY total DESC
    """).fetchall()
    recent = conn.execute("""
        SELECT date, card_type, card_last4, merchant, amount, currency, category
        FROM transactions ORDER BY date DESC LIMIT 20
    """).fetchall()
    monthly = conn.execute("""
        SELECT strftime('%Y-%m', date) as month, ROUND(SUM(amount), 2) as total, currency
        FROM transactions WHERE currency = 'UYU'
        GROUP BY month ORDER BY month DESC LIMIT 12
    """).fetchall()
    conn.close()
    return {
        "monthly_total": round(monthly_total[0], 2) if monthly_total else 0,
        "currency":      monthly_total[1] if monthly_total and monthly_total[1] else "UYU",
        "total_count":   total_count,
        "by_category":   by_category,
        "recent":        recent,
        "monthly":       monthly,
        "this_month":    this_month,
    }

@app.route("/")
def index():
    stats   = get_stats()
    paused  = is_paused()
    running = request.args.get("running", "0") == "1"
    return render_template("index.html", stats=stats, paused=paused, running=running, active="dashboard")

@app.route("/config", methods=["GET"])
def config_page():
    cfg    = load_config()
    paused = is_paused()
    return render_template("index.html", cfg=cfg, paused=paused, running=False, active="config")

@app.route("/config", methods=["POST"])
@limiter.limit("10 per minute")
def save_config_route():
    cfg = load_config()
    cfg["imap_host"]      = request.form.get("imap_host", cfg.get("imap_host", ""))
    cfg["imap_port"]      = int(request.form.get("imap_port") or cfg.get("imap_port") or 993)
    cfg["email_user"]     = request.form.get("email_user", cfg.get("email_user", ""))
    cfg["email_password"] = request.form.get("email_password", cfg.get("email_password", ""))
    cfg["sender_filter"]  = request.form.get("sender_filter", cfg.get("sender_filter", ""))
    raw_categories = request.form.get("categories_raw", "")
    categories = {}
    for line in raw_categories.splitlines():
        if ":" in line:
            cat, _, kws = line.partition(":")
            categories[cat.strip()] = [k.strip() for k in kws.split(",") if k.strip()]
    cfg["categories"] = categories
    save_config(cfg)
    return redirect(url_for("config_page"))

@app.route("/log")
@csrf.exempt
@limiter.exempt
def log_json():
    return jsonify({"log": read_log()})

@app.route("/run", methods=["POST"])
@limiter.limit("5 per minute")
def run():
    if is_paused():
        return redirect(url_for("index"))
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    with open(LOG_FILE, "a") as log:
        subprocess.Popen(["python", "/app/fetch.py"], stdout=log, stderr=log)
    return redirect(url_for("index", running=1))

@app.route("/toggle-pause", methods=["POST"])
@limiter.limit("10 per minute")
def toggle_pause():
    if is_paused():
        os.remove(PAUSE_FILE)
    else:
        open(PAUSE_FILE, "w").close()
    return redirect(url_for("index"))

@app.route("/reset", methods=["POST"])
@limiter.limit("3 per minute")
def reset():
    if os.path.exists(DB_PATH):
        conn = sqlite3.connect(DB_PATH)
        conn.execute("DELETE FROM transactions")
        conn.commit()
        conn.close()
    if os.path.exists(LOG_FILE):
        open(LOG_FILE, "w").close()
    return redirect(url_for("index"))

