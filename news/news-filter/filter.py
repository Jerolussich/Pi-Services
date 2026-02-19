#!/usr/bin/env python3
import os
import sqlite3
import requests
import logging
from datetime import datetime, timedelta, timezone

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)

# ── Config ────────────────────────────────────────────────────────────────────
FRESHRSS_URL        = os.environ["FRESHRSS_URL"].rstrip("/")
FRESHRSS_USER       = os.environ["FRESHRSS_USERNAME"]
FRESHRSS_PASS       = os.environ["FRESHRSS_API_PASSWORD"]
WALLABAG_URL        = os.environ["WALLABAG_URL"].rstrip("/")
WALLABAG_CLIENT     = os.environ["WALLABAG_CLIENT_ID"]
WALLABAG_SECRET     = os.environ["WALLABAG_CLIENT_SECRET"]
WALLABAG_USER       = os.environ["WALLABAG_USERNAME"]
WALLABAG_PASS       = os.environ["WALLABAG_PASSWORD"]
EXTRA_KEYWORDS      = os.environ.get("EXTRA_KEYWORDS", "")
MIN_CONTENT_LEN     = int(os.environ.get("MIN_CONTENT_LENGTH", "500"))
SEEN_RETENTION_DAYS = int(os.environ.get("SEEN_RETENTION_DAYS", "30"))
LOG_RETENTION_DAYS  = int(os.environ.get("LOG_RETENTION_DAYS", "90"))
DB_PATH             = "/app/data/seen.db"
KEYWORDS_FILE       = "/app/config/keywords.txt"
LOG_FILE            = "/app/data/filter.log"
PAUSE_FILE          = "/app/data/paused"

# ── Log rotation ──────────────────────────────────────────────────────────────
def rotate_log():
    if not os.path.exists(LOG_FILE):
        return
    cutoff = datetime.now() - timedelta(days=LOG_RETENTION_DAYS)
    kept = []
    with open(LOG_FILE) as f:
        for line in f:
            try:
                # Lines start with "YYYY-MM-DD HH:MM:SS,mmm"
                date_str = line[:10]
                if datetime.strptime(date_str, "%Y-%m-%d") >= cutoff:
                    kept.append(line)
            except ValueError:
                kept.append(line)  # Keep lines that don't parse
    with open(LOG_FILE, "w") as f:
        f.writelines(kept)
    log.info(f"Log rotated — kept entries from last {LOG_RETENTION_DAYS} days")

# ── Keywords ──────────────────────────────────────────────────────────────────
def load_keywords():
    keywords = []
    if os.path.exists(KEYWORDS_FILE):
        with open(KEYWORDS_FILE) as f:
            keywords = [l.strip().lower() for l in f if l.strip() and not l.startswith("#")]
    if EXTRA_KEYWORDS:
        keywords += [k.strip().lower() for k in EXTRA_KEYWORDS.split(",") if k.strip()]
    return list(set(keywords))

def matches_keywords(text, keywords):
    text = text.lower()
    return any(kw in text for kw in keywords)

# ── SQLite dedup ──────────────────────────────────────────────────────────────
def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS seen (
            url TEXT PRIMARY KEY,
            saved_at TEXT,
            wallabag_id INTEGER
        )
    """)
    try:
        conn.execute("ALTER TABLE seen ADD COLUMN wallabag_id INTEGER")
        conn.commit()
    except sqlite3.OperationalError:
        pass
    conn.commit()
    return conn

def cleanup_old(conn, wb_token):
    rows = conn.execute(
        "SELECT url, wallabag_id FROM seen WHERE saved_at < date('now', ?)",
        (f"-{SEEN_RETENTION_DAYS} days",)
    ).fetchall()

    deleted_wb = 0
    for url, wallabag_id in rows:
        if wallabag_id:
            try:
                wallabag_delete(wb_token, wallabag_id)
                deleted_wb += 1
            except Exception as e:
                log.warning(f"Could not delete Wallabag entry {wallabag_id}: {e}")

    cursor = conn.execute(
        "DELETE FROM seen WHERE saved_at < date('now', ?)",
        (f"-{SEEN_RETENTION_DAYS} days",)
    )
    conn.commit()
    if cursor.rowcount > 0:
        log.info(f"Cleaned up {cursor.rowcount} old entries from seen.db, {deleted_wb} deleted from Wallabag")

def is_seen(conn, url):
    return conn.execute("SELECT 1 FROM seen WHERE url = ?", (url,)).fetchone() is not None

def mark_seen(conn, url, wallabag_id=None):
    conn.execute(
        "INSERT OR IGNORE INTO seen VALUES (?, ?, ?)",
        (url, datetime.now().isoformat(), wallabag_id)
    )
    conn.commit()

# ── FreshRSS API ──────────────────────────────────────────────────────────────
def freshrss_auth():
    resp = requests.post(
        f"{FRESHRSS_URL}/api/greader.php/accounts/ClientLogin",
        data={"Email": FRESHRSS_USER, "Passwd": FRESHRSS_PASS},
    )
    resp.raise_for_status()
    for line in resp.text.splitlines():
        if line.startswith("Auth="):
            return line[5:]
    raise Exception("FreshRSS auth failed")

def freshrss_articles(token):
    since = int((datetime.now(timezone.utc) - timedelta(hours=24)).timestamp())
    resp = requests.get(
        f"{FRESHRSS_URL}/api/greader.php/reader/api/0/stream/contents/reading-list",
        headers={"Authorization": f"GoogleLogin auth={token}"},
        params={"ot": since, "n": 200},
    )
    resp.raise_for_status()
    return resp.json().get("items", [])

# ── Wallabag API ──────────────────────────────────────────────────────────────
def wallabag_token():
    resp = requests.post(f"{WALLABAG_URL}/oauth/v2/token", data={
        "grant_type":    "password",
        "client_id":     WALLABAG_CLIENT,
        "client_secret": WALLABAG_SECRET,
        "username":      WALLABAG_USER,
        "password":      WALLABAG_PASS,
    })
    resp.raise_for_status()
    return resp.json()["access_token"]

def wallabag_save(token, url, title=""):
    resp = requests.post(
        f"{WALLABAG_URL}/api/entries.json",
        headers={"Authorization": f"Bearer {token}"},
        json={"url": url, "title": title},
    )
    resp.raise_for_status()
    return resp.json()

def wallabag_delete(token, entry_id):
    requests.delete(
        f"{WALLABAG_URL}/api/entries/{entry_id}.json",
        headers={"Authorization": f"Bearer {token}"},
    )

def wallabag_delete_all(token):
    """Delete all Wallabag entries tracked in seen.db"""
    conn = sqlite3.connect(DB_PATH)
    rows = conn.execute("SELECT wallabag_id FROM seen WHERE wallabag_id IS NOT NULL").fetchall()
    conn.close()
    deleted = 0
    for (wallabag_id,) in rows:
        try:
            wallabag_delete(token, wallabag_id)
            deleted += 1
        except Exception as e:
            log.warning(f"Could not delete Wallabag entry {wallabag_id}: {e}")
    return deleted

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    # Check if paused
    if os.path.exists(PAUSE_FILE):
        log.info("Filter is paused — delete /app/data/paused to resume")
        return

    log.info("Starting news-filter run")
    keywords = load_keywords()
    log.info(f"Keywords loaded: {keywords}")

    rotate_log()

    conn     = init_db()
    wb_token = wallabag_token()
    cleanup_old(conn, wb_token)

    fr_token = freshrss_auth()
    articles = freshrss_articles(fr_token)
    log.info(f"Fetched {len(articles)} articles from FreshRSS")

    saved = skipped = filtered = 0

    for item in articles:
        url   = item.get("canonical", [{}])[0].get("href", "")
        title = item.get("title", "")

        if not url:
            continue
        if is_seen(conn, url):
            skipped += 1
            continue

        content = item.get("summary", {}).get("content", "") or \
                  item.get("content", {}).get("content", "")
        text    = f"{title} {content}"

        wb_entry = None
        if len(content) < MIN_CONTENT_LEN:
            log.info(f"Short content ({len(content)} chars), fetching via Wallabag: {url}")
            try:
                wb_entry = wallabag_save(wb_token, url, title)
                content  = wb_entry.get("content", "") or ""
                text     = f"{title} {content}"
            except Exception as e:
                log.warning(f"Wallabag fetch failed for {url}: {e}")

        if matches_keywords(text, keywords):
            if not wb_entry:
                try:
                    wb_entry = wallabag_save(wb_token, url, title)
                except Exception as e:
                    log.warning(f"Could not save to Wallabag: {e}")
            wallabag_id = wb_entry["id"] if wb_entry else None
            mark_seen(conn, url, wallabag_id)
            log.info(f"✓ Saved: {title}")
            saved += 1
        else:
            if wb_entry:
                wallabag_delete(wb_token, wb_entry["id"])
            mark_seen(conn, url, None)
            filtered += 1

    log.info(f"Done — saved: {saved}, filtered: {filtered}, skipped (seen): {skipped}")

if __name__ == "__main__":
    main()
