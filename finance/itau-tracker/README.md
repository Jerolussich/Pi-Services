# Itaú Tracker

Automatically reads Itaú credit card purchase notification emails from a Hotmail/Outlook account via the Microsoft Graph API, parses transaction details, stores them in SQLite, and visualizes them in Grafana.

---

## Architecture

```
Microsoft Graph API
        ↓ (hourly cron)
  itau-tracker (fetch.py)
        ↓
  finance.db (SQLite)
        ↓
  itau-tracker-ui (Flask)
  Grafana via SQLite datasource
```

Both containers are defined in a single `docker-compose.yml` and share a `data/` bind mount.

The Grafana dashboard and provisioning live in `monitoring/grafana/` alongside the Fitbit dashboards — Grafana is managed entirely from the monitoring service.

---

## Directory Structure

```
finance/
└── itau-tracker/
    ├── docker-compose.yml
    ├── .env                        ← gitignored (UI_USERNAME, UI_PASSWORD, SECRET_KEY)
    ├── .env.example
    ├── tracker/
    │   ├── Dockerfile
    │   ├── fetch.py
    │   ├── auth.py
    │   └── requirements.txt
    ├── ui/
    │   ├── Dockerfile
    │   ├── app.py
    │   ├── requirements.txt
    │   └── templates/
    │       └── index.html
    └── data/                       ← gitignored, bind-mounted into both containers
        ├── finance.db
        ├── config.json             ← runtime config, editable from UI
        ├── token.json              ← gitignored (Microsoft OAuth2 tokens)
        ├── tracker.log
        └── paused                  ← sentinel file to pause the cron

monitoring/
└── grafana/
    ├── dashboards/
    │   ├── fitbit/
    │   └── finance/
    │       └── finance_dashboard.json
    └── provisioning/
        └── dashboards/
            └── fitbit.yaml
```

---

## Setup

### Prerequisites

- Microsoft Azure account (free tier is sufficient)
- Hotmail/Outlook account receiving Itaú purchase notifications
- Itaú configured to send email notifications on every purchase

### 1. Azure App Registration

1. Go to `https://aka.ms/AppRegistrations` and sign in with your Microsoft account
2. Click **New registration** — name: `itau-tracker`, personal accounts only
3. Go to **Manage → Authentication** → enable **Allow public client flows** → Save
4. Go to **Manage → API permissions** → Microsoft Graph → Delegated → `Mail.Read` → Grant admin consent
5. Go to **Manage → Certificates & secrets** → New client secret → copy the **Value** immediately
6. Note your **Application (client) ID** from the Overview page

### 2. Configure .env

```bash
cp finance/itau-tracker/.env.example finance/itau-tracker/.env
```

**`finance/itau-tracker/.env`**
```
UI_USERNAME=admin
UI_PASSWORD=your_ui_password
SECRET_KEY=your_secret_key
```

Generate `SECRET_KEY` with:
```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```

### 3. Create data folder and config.json

```bash
mkdir -p finance/itau-tracker/data

cat > finance/itau-tracker/data/config.json << 'EOF'
{
  "client_id": "your_azure_client_id",
  "client_secret": "your_azure_client_secret",
  "tenant_id": "consumers",
  "sender_filter": "comunicaciones@itau.com.uy",
  "categories": {
    "supermercado": ["tienda inglesa", "tienda inlgesa", "disco", "devoto", "geant", "tata", "fresh market"],
    "restaurant": ["mc donald", "mcdonald", "burger", "pizza", "sushi", "resto", "bar ", "cafe", "coffee", "parrilla", "frog"],
    "transporte": ["uber", "cabify", "cut", "copsa", "turil"],
    "farmacia": ["farmacia", "pharmacy"],
    "combustible": ["ancap", "petrobras", "axion", "esso"],
    "tecnologia": ["apple", "google", "amazon", "netflix", "spotify", "microsoft", "steam"],
    "ropa": ["zara", "h&m", "mango"],
    "salud": ["mutualista", "medica", "clinica", "hospital", "dental"],
    "entretenimiento": ["cinema", "movie", "teatro", "tickantel", "antel arena"]
  }
}
EOF
```

### 4. Add finance path to monitoring/.env

```bash
echo "FINANCE_DATA_PATH=/home/youruser/pi-services/finance/itau-tracker/data" >> monitoring/.env
```

### 5. Build and start containers

```bash
docker compose up -d --build itau-tracker itau-tracker-ui
```

### 6. One-time authorization

```bash
docker exec -it itau-tracker python /app/auth.py
```

Open the printed URL, enter the code, sign in with your Hotmail account. `data/token.json` is saved automatically.

### 7. Run first fetch

```bash
docker exec itau-tracker python /app/fetch.py
```

### 8. Configure Grafana SQLite datasource

1. In Grafana go to **Connections → Data sources → Add data source → SQLite**
2. Path: `///var/finance/finance.db`
3. **Save & test** — note the datasource UID from the browser URL
4. Update dashboard JSON:
   ```bash
   sed -i 's/finance-sqlite/your_uid_here/g' monitoring/grafana/dashboards/finance/finance_dashboard.json
   docker compose restart grafana
   ```

---

## How It Works

### fetch.py — hourly cron

1. Checks for `data/paused` sentinel file — exits if paused
2. Loads `config.json` and `token.json`
3. Refreshes `access_token` via Microsoft — saves updated tokens
4. Calls Graph API: `GET /me/messages?$search="from:comunicaciones@itau.com.uy AND subject:consumo aprobado"`
5. For each new email: parses HTML body, extracts card type/last4/amount/currency/merchant, categorizes, inserts into `finance.db`
6. Logs to `data/tracker.log`

### Token lifecycle

- `access_token` expires every 60 minutes — refreshed automatically on every cron run
- `refresh_token` valid for 90 days — renewed on every successful refresh
- If expired, re-run `auth.py` once

### finance.db Schema

```sql
CREATE TABLE transactions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    email_id    TEXT UNIQUE,
    date        TEXT,
    card_type   TEXT,
    card_last4  TEXT,
    amount      REAL,
    currency    TEXT,
    merchant    TEXT,
    category    TEXT
);
```

---

## itau-tracker-ui

Flask web UI at `http://finance.pi`. Protected with HTTP Basic Auth via `UI_USERNAME` / `UI_PASSWORD`.

### Security

CSRF protection (`flask-wtf`) and rate limiting (`flask-limiter`) are enabled on all POST endpoints:

| Endpoint | Limit |
|---|---|
| `/run` | 5/min |
| `/toggle-pause` | 10/min |
| `/config` POST | 10/min |
| `/reset` | 3/min |
| `/log` | exempt (GET, used by live polling) |

All forms include a CSRF token — POST requests without a valid token + session cookie are rejected with `400`. IPs exceeding the rate limit receive `429`.

### Features

**Dashboard tab** — this month's total, transaction count, monthly bar chart, category chart, recent transactions table, live run log.

**Config tab** — edit Azure credentials, sender filter, and category keyword lists. Changes saved to `data/config.json` without rebuild.

**Header controls** — **▶ Run now** triggers fetch immediately with live log. **⏸ Pause / ▶ Resume** pauses/resumes the hourly cron.

**Danger Zone** — **🗑 Delete all data** clears all transactions and the log.

---

## Grafana Dashboards

Lives in `monitoring/grafana/dashboards/finance/`, provisioned automatically. Reads from `finance.db` via the Finance SQLite datasource at `/var/finance/finance.db`.

---

## Volumes

| Path (host) | Path (container) | Service |
|---|---|---|
| `./data` | `/app/data` | tracker + ui |
| `./tracker/fetch.py` | `/app/fetch.py` | ui (for Run now) |
| `finance/itau-tracker/data` | `/var/finance` | grafana (read-only) |

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `400 Bad Request` on device code | Enable **Allow public client flows** in Azure → Authentication |
| `Token refresh failed: 400` | Use `"tenant_id": "consumers"` in `config.json` |
| `card:None` in logs | Rebuild after regex fix |
| Token expired after 90 days | Re-run `docker exec -it itau-tracker python /app/auth.py` |
| Dashboard shows no data | Verify datasource UID matches — update with `sed` |
| UI returns 400 on form submit | CSRF token missing — browser submits automatically, curl requires session cookie |
| UI returns 429 | Rate limit hit — wait 1 minute |
