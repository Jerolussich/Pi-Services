#!/usr/bin/env python3
import requests
import sqlite3
import json
import os
import re
import logging
from datetime import datetime
from bs4 import BeautifulSoup

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)

CONFIG_PATH = "/app/data/config.json"
TOKEN_PATH  = "/app/data/token.json"
DB_PATH     = "/app/data/finance.db"
PAUSE_FILE  = "/app/data/paused"

def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)

def load_tokens():
    if not os.path.exists(TOKEN_PATH):
        raise Exception("No token.json found — run auth.py first")
    with open(TOKEN_PATH) as f:
        return json.load(f)

def save_tokens(tokens):
    with open(TOKEN_PATH, "w") as f:
        json.dump(tokens, f, indent=2)

def get_access_token(config, tokens):
    if "refresh_token" in tokens:
        resp = requests.post(
            "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
            data={
                "grant_type":    "refresh_token",
                "client_id":     config["client_id"],
                "refresh_token": tokens["refresh_token"],
                "scope":         "https://graph.microsoft.com/Mail.Read offline_access",
            }
        )
        if resp.ok:
            new_tokens = resp.json()
            save_tokens(new_tokens)
            return new_tokens["access_token"]

    log.warning("No refresh token — using existing access token (may be expired)")
    return tokens["access_token"]

def get_emails(access_token, sender_filter):
    headers = {"Authorization": f"Bearer {access_token}"}
    url = (
        "https://graph.microsoft.com/v1.0/me/messages"
        f"?$search=\"from:{sender_filter} AND subject:consumo aprobado\""
        "&$select=id,subject,receivedDateTime,body"
        "&$top=100"
    )
    emails = []
    while url:
        resp = requests.get(url, headers=headers)
        resp.raise_for_status()
        data = resp.json()
        emails.extend(data.get("value", []))
        url = data.get("@odata.nextLink")
    return emails

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
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
    conn.commit()
    return conn

def categorize(merchant, categories):
    merchant_lower = merchant.lower()
    for category, keywords in categories.items():
        if any(kw.lower() in merchant_lower for kw in keywords):
            return category
    return "otros"

def parse_transaction(email_data, categories):
    date_str = email_data.get("receivedDateTime", "")
    try:
        date = datetime.fromisoformat(date_str.replace("Z", "+00:00")).isoformat()
    except Exception:
        date = datetime.now().isoformat()

    body_content = email_data.get("body", {}).get("content", "")
    soup = BeautifulSoup(body_content, "html.parser")
    text = soup.get_text(separator=" ")

    card_type  = None
    card_last4 = None
    amount     = None
    currency   = None
    merchant   = None

    card_match = re.search(r'(VISA|MASTER(?:CARD)?|AMEX|OCA)\s+nro\.\s*\*+\s*(\d{4})', text, re.IGNORECASE)
    if card_match:
        card_type  = card_match.group(1).upper()
        card_last4 = card_match.group(2)

    amount_match = re.search(r'Importe:\s*([\d.,]+)\s*([A-Z]{3})', text)
    if amount_match:
        amount   = float(amount_match.group(1).replace(",", "."))
        currency = amount_match.group(2)

    merchant_match = re.search(r'Comercio:\s*(.+?)(?:\s{2,}|<|\n|\r|$)', text)
    if merchant_match:
        merchant = re.sub(r'\s+', ' ', merchant_match.group(1)).strip()

    if not all([card_type, amount, merchant]):
        log.warning(f"Could not extract all fields — card:{card_type} amount:{amount} merchant:{merchant}")
        return None

    return {
        "date":       date,
        "card_type":  card_type,
        "card_last4": card_last4,
        "amount":     amount,
        "currency":   currency or "UYU",
        "merchant":   merchant,
        "category":   categorize(merchant, categories),
    }

def main():
    if os.path.exists(PAUSE_FILE):
        log.info("Tracker is paused — delete /app/data/paused to resume")
        return

    log.info("Starting itau-tracker run")
    config = load_config()
    tokens = load_tokens()
    conn   = init_db()

    try:
        access_token = get_access_token(config, tokens)
        log.info("Access token ready")
    except Exception as e:
        log.error(f"Token error: {e}")
        return

    try:
        emails = get_emails(access_token, config["sender_filter"])
        log.info(f"Found {len(emails)} emails from Itaú")
    except Exception as e:
        log.error(f"Graph API request failed: {e}")
        return

    saved = skipped = errors = 0

    for email_data in emails:
        email_id = email_data["id"]

        if conn.execute("SELECT 1 FROM transactions WHERE email_id = ?", (email_id,)).fetchone():
            skipped += 1
            continue

        try:
            tx = parse_transaction(email_data, config.get("categories", {}))
            if tx:
                conn.execute("""
                    INSERT INTO transactions (email_id, date, card_type, card_last4, amount, currency, merchant, category)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, (email_id, tx["date"], tx["card_type"], tx["card_last4"],
                      tx["amount"], tx["currency"], tx["merchant"], tx["category"]))
                conn.commit()
                log.info(f"✓ {tx['date'][:10]} | {tx['merchant']} | {tx['amount']} {tx['currency']} | {tx['category']}")
                saved += 1
            else:
                errors += 1
        except Exception as e:
            log.error(f"Error processing {email_id}: {e}")
            errors += 1

    log.info(f"Done — saved: {saved}, skipped (seen): {skipped}, errors: {errors}")

if __name__ == "__main__":
    main()
