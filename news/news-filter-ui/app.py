from flask import Flask, render_template, request, redirect, url_for
import subprocess
import sqlite3
import os

app = Flask(__name__)

KEYWORDS_FILE = "/app/config/keywords.txt"
LOG_FILE      = "/app/data/filter.log"
DB_PATH       = "/app/data/seen.db"
PAUSE_FILE    = "/app/data/paused"

def read_keywords():
    if not os.path.exists(KEYWORDS_FILE):
        return []
    with open(KEYWORDS_FILE) as f:
        return [l.strip() for l in f if l.strip() and not l.startswith("#")]

def write_keywords(keywords):
    with open(KEYWORDS_FILE, "w") as f:
        f.write("\n".join(keywords) + "\n")

def read_log():
    if not os.path.exists(LOG_FILE):
        return "No runs yet."
    with open(LOG_FILE) as f:
        lines = f.readlines()
    return "".join(lines[-100:])

def is_paused():
    return os.path.exists(PAUSE_FILE)

@app.route("/", methods=["GET"])
def index():
    keywords = read_keywords()
    log      = read_log()
    paused   = is_paused()
    return render_template("index.html", keywords=keywords, log=log, paused=paused)

@app.route("/save", methods=["POST"])
def save():
    raw      = request.form.get("keywords", "")
    keywords = [l.strip() for l in raw.splitlines() if l.strip()]
    write_keywords(keywords)
    return redirect(url_for("index"))

@app.route("/run", methods=["POST"])
def run():
    if is_paused():
        return redirect(url_for("index"))
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    with open(LOG_FILE, "a") as log:
        subprocess.Popen(
            ["python", "/app/filter.py"],
            stdout=log,
            stderr=log,
        )
    return redirect(url_for("index"))

@app.route("/toggle-pause", methods=["POST"])
def toggle_pause():
    if is_paused():
        os.remove(PAUSE_FILE)
    else:
        open(PAUSE_FILE, "w").close()
    return redirect(url_for("index"))

@app.route("/reset", methods=["POST"])
def reset():
    import requests as req

    wallabag_url  = os.environ["WALLABAG_URL"].rstrip("/")
    client_id     = os.environ["WALLABAG_CLIENT_ID"]
    client_secret = os.environ["WALLABAG_CLIENT_SECRET"]
    username      = os.environ["WALLABAG_USERNAME"]
    password      = os.environ["WALLABAG_PASSWORD"]
    freshrss_url  = os.environ["FRESHRSS_URL"].rstrip("/")
    freshrss_user = os.environ["FRESHRSS_USERNAME"]
    freshrss_pass = os.environ["FRESHRSS_API_PASSWORD"]

    # ── Delete Wallabag entries ───────────────────────────────────────────────
    try:
        resp  = req.post(f"{wallabag_url}/oauth/v2/token", data={
            "grant_type":    "password",
            "client_id":     client_id,
            "client_secret": client_secret,
            "username":      username,
            "password":      password,
        })
        token = resp.json()["access_token"]

        if os.path.exists(DB_PATH):
            conn = sqlite3.connect(DB_PATH)
            rows = conn.execute("SELECT wallabag_id FROM seen WHERE wallabag_id IS NOT NULL").fetchall()
            conn.close()
            for (wallabag_id,) in rows:
                try:
                    req.delete(
                        f"{wallabag_url}/api/entries/{wallabag_id}.json",
                        headers={"Authorization": f"Bearer {token}"},
                    )
                except Exception:
                    pass
    except Exception:
        pass

    # ── Mark all FreshRSS articles as read ───────────────────────────────────
    try:
        auth_resp = req.post(
            f"{freshrss_url}/api/greader.php/accounts/ClientLogin",
            data={"Email": freshrss_user, "Passwd": freshrss_pass},
        )
        fr_token = None
        for line in auth_resp.text.splitlines():
            if line.startswith("Auth="):
                fr_token = line[5:]
                break

        if fr_token:
            req.post(
                f"{freshrss_url}/api/greader.php/reader/api/0/mark-all-as-read",
                headers={"Authorization": f"GoogleLogin auth={fr_token}"},
                data={"s": "user/-/state/com.google/reading-list", "ts": "0"},
            )
    except Exception:
        pass

    # ── Clear seen.db ─────────────────────────────────────────────────────────
    if os.path.exists(DB_PATH):
        conn = sqlite3.connect(DB_PATH)
        conn.execute("DELETE FROM seen")
        conn.commit()
        conn.close()

    # ── Clear log ─────────────────────────────────────────────────────────────
    if os.path.exists(LOG_FILE):
        open(LOG_FILE, "w").close()

    return redirect(url_for("index"))

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8084)
