from flask import Flask, render_template, request, redirect, url_for, Response, jsonify, flash, get_flashed_messages
from flask_wtf.csrf import CSRFProtect
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from werkzeug.utils import secure_filename
import subprocess
import sqlite3
import tempfile
import json
import os
from parsers import BANKS, BankMismatchError, get_parser

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY") or os.urandom(32)
app.config["MAX_CONTENT_LENGTH"] = 10 * 1024 * 1024
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

def ensure_schema(conn):
    conn.execute("""
        CREATE TABLE IF NOT EXISTS transactions (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            email_id    TEXT UNIQUE,
            date        TEXT,
            card_type   TEXT,
            card_last4  TEXT,
            amount      REAL,
            currency    TEXT,
            merchant    TEXT,
            category    TEXT
        )
    """)
    existing = {row[1] for row in conn.execute("PRAGMA table_info(transactions)").fetchall()}
    if "source" not in existing:
        conn.execute("ALTER TABLE transactions ADD COLUMN source TEXT DEFAULT 'email'")
    if "direction" not in existing:
        conn.execute("ALTER TABLE transactions ADD COLUMN direction TEXT DEFAULT 'debit'")
    if "movement_type" not in existing:
        conn.execute("ALTER TABLE transactions ADD COLUMN movement_type TEXT")
    if "account" not in existing:
        conn.execute("ALTER TABLE transactions ADD COLUMN account TEXT")
    conn.commit()

def get_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    ensure_schema(conn)
    return conn

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

def categorize(merchant, categories, movement_type=None):
    haystack = f"{movement_type or ''} {merchant or ''}".lower()
    for cat, kws in categories.items():
        if any(kw.lower() in haystack for kw in kws):
            return cat
    return "otros"

def get_stats():
    conn = get_db()
    from datetime import datetime
    now        = datetime.now()
    this_month = now.strftime("%Y-%m")
    monthly_expense = conn.execute("""
        SELECT COALESCE(SUM(amount), 0) FROM transactions
        WHERE strftime('%Y-%m', date) = ? AND currency = 'UYU' AND direction = 'debit'
    """, (this_month,)).fetchone()[0]
    monthly_income = conn.execute("""
        SELECT COALESCE(SUM(amount), 0) FROM transactions
        WHERE strftime('%Y-%m', date) = ? AND currency = 'UYU' AND direction = 'credit'
    """, (this_month,)).fetchone()[0]
    total_count = conn.execute("SELECT COUNT(*) FROM transactions").fetchone()[0]
    by_category = conn.execute("""
        SELECT category, ROUND(SUM(amount), 2) as total FROM transactions
        WHERE currency = 'UYU' AND direction = 'debit'
        GROUP BY category ORDER BY total DESC
    """).fetchall()
    recent = conn.execute("""
        SELECT date, card_type, card_last4, merchant, amount, currency, category, direction, source, movement_type, account
        FROM transactions ORDER BY date DESC, id DESC LIMIT 30
    """).fetchall()
    by_account = conn.execute("""
        SELECT COALESCE(account, 'Itaú tarjeta (email)') as acc,
               SUM(CASE WHEN direction='debit'  THEN amount ELSE 0 END) as out_total,
               SUM(CASE WHEN direction='credit' THEN amount ELSE 0 END) as in_total,
               currency, COUNT(*) as n
        FROM transactions GROUP BY acc, currency ORDER BY n DESC
    """).fetchall()
    monthly_out = conn.execute("""
        SELECT strftime('%Y-%m', date) as month, ROUND(SUM(amount), 2) as total
        FROM transactions WHERE currency = 'UYU' AND direction = 'debit'
        GROUP BY month ORDER BY month DESC LIMIT 12
    """).fetchall()
    monthly_in = conn.execute("""
        SELECT strftime('%Y-%m', date) as month, ROUND(SUM(amount), 2) as total
        FROM transactions WHERE currency = 'UYU' AND direction = 'credit'
        GROUP BY month ORDER BY month DESC LIMIT 12
    """).fetchall()
    conn.close()
    return {
        "monthly_total":   round(monthly_expense, 2),
        "monthly_income":  round(monthly_income, 2),
        "currency":        "UYU",
        "total_count":     total_count,
        "by_category":     by_category,
        "recent":          recent,
        "monthly":         monthly_out,
        "monthly_income_series": monthly_in,
        "by_account":      by_account,
        "this_month":      this_month,
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

def known_accounts():
    conn = get_db()
    rows = conn.execute("""
        SELECT account, COUNT(*) as n FROM transactions
        WHERE account IS NOT NULL AND account != ''
        GROUP BY account ORDER BY n DESC
    """).fetchall()
    conn.close()
    return [r[0] for r in rows]

@app.route("/upload", methods=["GET"])
def upload_page():
    paused = is_paused()
    return render_template("index.html", paused=paused, running=False,
                           active="upload", accounts=known_accounts(), banks=BANKS)

@app.route("/upload", methods=["POST"])
@limiter.limit("10 per minute")
def upload_pdf():
    f = request.files.get("pdf")
    bank = (request.form.get("bank") or "").strip()
    account = (request.form.get("account") or "").strip()
    parser = get_parser(bank)
    if not parser:
        flash(("error", f"No parser available for bank '{bank or '(none)'}'. Supported: {', '.join(b for b, _ in BANKS)}"))
        return redirect(url_for("upload_page"))
    if not account:
        flash(("error", "Please enter an account name (e.g. 'Itaú UYU', 'Itaú USD')"))
        return redirect(url_for("upload_page"))
    if not f or not f.filename:
        flash(("error", "No file selected"))
        return redirect(url_for("upload_page"))
    filename = secure_filename(f.filename)
    if not filename.lower().endswith(".pdf"):
        flash(("error", "File must be a PDF"))
        return redirect(url_for("upload_page"))

    with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as tmp:
        f.save(tmp.name)
        tmp_path = tmp.name

    try:
        txs = parser.parse_pdf(tmp_path, account=account)
    except BankMismatchError as e:
        flash(("error", str(e)))
        os.unlink(tmp_path)
        return redirect(url_for("upload_page"))
    except subprocess.CalledProcessError as e:
        flash(("error", f"Could not read PDF: {e}"))
        os.unlink(tmp_path)
        return redirect(url_for("upload_page"))
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)

    cfg = load_config()
    categories = cfg.get("categories", {})
    conn = get_db()
    saved = skipped = 0
    for tx in txs:
        exists = conn.execute("SELECT 1 FROM transactions WHERE email_id = ?", (tx["external_id"],)).fetchone()
        if exists:
            skipped += 1
            continue
        category = categorize(tx["merchant"], categories, tx["movement"])
        conn.execute("""
            INSERT INTO transactions (email_id, date, card_type, card_last4, amount, currency, merchant, category, source, direction, movement_type, account)
            VALUES (?, ?, ?, NULL, ?, ?, ?, ?, 'pdf', ?, ?, ?)
        """, (tx["external_id"], tx["date"], tx["movement"], tx["amount"], tx["currency"],
              tx["merchant"], category, tx["direction"], tx["movement"], account))
        saved += 1
    conn.commit()
    conn.close()
    flash(("ok", f"[{account}] Imported {saved} new transactions — skipped {skipped} duplicates (from {len(txs)} in PDF)"))
    return redirect(url_for("upload_page"))
