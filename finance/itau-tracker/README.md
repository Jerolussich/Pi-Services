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
  itau-tracker-ui (Flask :8085)
  Grafana (:3000) via SQLite datasource
```

Both containers are defined in a single `docker-compose.yml` and share a `data/` bind mount.

---

## Directory Structure

```
finance/
└── itau-tracker/
    ├── docker-compose.yml          ← defines both itau-tracker + itau-tracker-ui
    ├── .env                        ← gitignored (UI_USERNAME, UI_PASSWORD)
    ├── .env.example
    ├── tracker/
    │   ├── Dockerfile              ← cron container
    │   ├── fetch.py                ← main fetch + parse + save script
    │   ├── auth.py                 ← one-time OAuth2 device code flow
    │   └── requirements.txt
    ├── ui/
    │   ├── Dockerfile              ← Flask UI container
    │   ├── app.py
    │   ├── requirements.txt
    │   └── templates/
    │       └── index.html
    ├── grafana/
    │   ├── dashboards/
    │   │   └── finance_dashboard.json
    │   └── provisioning/
    │       ├── dashboards/
    │       │   └── finance.yaml
    │       └── datasources/
    │           └── finance.yaml
    └── data/                       ← gitignored, bind-mounted into both containers
        ├── finance.db              ← SQLite with all transactions
        ├── config.json             ← runtime config (email, categories) — editable from UI
        ├── token.json              ← gitignored (Microsoft OAuth2 tokens)
        ├── tracker.log
        └── paused                  ← sentinel file to pause the cron
```

---

## Setup

### Prerequisites

- Microsoft Azure account (free tier is sufficient)
- Hotmail/Outlook account receiving Itaú purchase notifications
- Itaú configured to send email notifications on every purchase

### 1. Azure App Registration

The tracker uses the Microsoft Graph API to read emails. A one-time Azure setup is required.

1. Go to `https://aka.ms/AppRegistrations` and sign in with your Microsoft account
2. Click **New registration**
   - Name: `itau-tracker`
   - Supported account types: **Personal accounts only**
3. Go to **Manage → Authentication**
   - Under **Supported accounts** select **Personal accounts only**
   - Under **Settings** enable **Allow public client flows** → Yes
   - Save
4. Go to **Manage → API permissions**
   - Add a permission → Microsoft Graph → Delegated → `Mail.Read`
   - Grant admin consent
5. Go to **Manage → Certificates & secrets**
   - New client secret → name `itau-tracker`, 24 months
   - Copy the **Value** immediately (shown only once)
6. Note your **Application (client) ID** from the Overview page

### 2. Configure environment files

```bash
cp finance/itau-tracker/.env.example finance/itau-tracker/.env
```

**`finance/itau-tracker/.env`**
```
UI_USERNAME=admin
UI_PASSWORD=your_ui_password
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

### 4. Add finance paths to monitoring/.env

```bash
echo "FINANCE_DATA_PATH=/home/youruser/pi-services/finance/itau-tracker/data" >> monitoring/.env
```

### 5. Build and start containers

```bash
docker compose up -d --build itau-tracker itau-tracker-ui
```

### 6. One-time authorization

This step authorizes the app to read your Hotmail inbox. Only needs to be done once — tokens are stored and auto-refreshed indefinitely.

```bash
docker exec -it itau-tracker python /app/auth.py
```

The script will print a URL and a short code. Open the URL in your browser, enter the code, and sign in with your Hotmail account. Once authorized, `data/token.json` is saved automatically.

### 7. Run first fetch

```bash
docker exec itau-tracker python /app/fetch.py
```

This fetches all historical Itaú purchase emails and populates `finance.db`.

### 8. Configure Grafana

1. In Grafana go to **Connections → Data sources → Add data source → SQLite**
2. Set:
   - Name: `Finance SQLite`
   - Path: `///var/finance/finance.db`
3. **Save & test** — note the datasource UID from the URL
4. Update the dashboard JSON to use your UID:
   ```bash
   sed -i 's/finance-sqlite/your_uid_here/g' finance/itau-tracker/grafana/dashboards/finance_dashboard.json
   docker compose restart grafana
   ```

---

## How It Works

### fetch.py — hourly cron

1. Checks for `data/paused` sentinel file — exits immediately if paused
2. Loads `config.json` and `token.json`
3. Uses `refresh_token` to get a new `access_token` from Microsoft — saves updated tokens
4. Calls Graph API: `GET /me/messages?$search="from:comunicaciones@itau.com.uy AND subject:consumo aprobado"`
5. For each email not already in `finance.db`:
   - Parses HTML body with BeautifulSoup
   - Extracts card type, last 4 digits, amount, currency, merchant
   - Categorizes merchant by keyword matching
   - Inserts into `finance.db`
6. Logs results to `data/tracker.log`

### Token lifecycle

- `access_token` — expires every 60 minutes, refreshed automatically on every cron run
- `refresh_token` — valid for 90 days, renewed on every successful refresh
- As long as the cron runs at least once every 90 days, tokens never expire
- If they do expire, re-run `auth.py` once to reauthorize

### finance.db Schema

```sql
CREATE TABLE transactions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    email_id    TEXT UNIQUE,      -- Graph API message ID (deduplication key)
    date        TEXT,             -- ISO 8601 timestamp
    card_type   TEXT,             -- VISA, MASTERCARD, etc.
    card_last4  TEXT,             -- last 4 digits
    amount      REAL,
    currency    TEXT,             -- UYU or USD
    merchant    TEXT,             -- cleaned merchant name
    category    TEXT              -- auto-categorized from config.json
);
```

### Categorization

Merchant names are matched against keyword lists in `config.json`. Categories are fully editable from the UI without rebuilding. If no keyword matches, the transaction is labeled `otros`.

---

## itau-tracker-ui

Flask web UI accessible at `http://<pi_ip>:8085`. Protected with HTTP Basic Auth via `UI_USERNAME` / `UI_PASSWORD` in `.env`.

**Dashboard tab:**
- This month's total spending (UYU)
- Total transaction count
- Average transaction amount
- Monthly spending bar chart (last 12 months)
- Spending by category bar chart
- Recent transactions table (last 20)
- Live run log

**Config tab:**
- Edit IMAP/Graph API credentials
- Edit category keyword lists
- Changes saved directly to `data/config.json` — no rebuild needed

**Controls (header):**
- **▶ Run now** — triggers `fetch.py` immediately with live log polling
- **⏸ Pause / ▶ Resume** — creates/deletes `data/paused` to pause/resume the hourly cron

**Danger Zone:**
- **🗑 Delete all data** — clears all transactions from `finance.db` and empties `tracker.log`

---

## Grafana Dashboards

The **Finance — Itaú Tracker** dashboard is provisioned automatically in the **Finance** folder. It includes:

- Total spending this month (stat)
- Transactions this month (stat)
- Average transaction amount (stat)
- Total transactions all time (stat)
- Monthly spending bar chart (last 12 months)
- Spending by category donut chart
- Top 10 merchants bar chart
- Recent transactions table

Dashboards read directly from `finance.db` via the SQLite datasource mounted at `/var/finance/finance.db` in the Grafana container.

---

## Volumes

| Path (host) | Path (container) | Description |
|---|---|---|
| `./data` | `/app/data` | DB, log, config, tokens, paused file |
| `./tracker/fetch.py` | `/app/fetch.py` | Mounted into UI container for Run now |
| `./grafana/dashboards` | `/var/lib/grafana/dashboards/finance` | Dashboard JSON |
| `./grafana/provisioning/dashboards` | `/etc/grafana/provisioning/dashboards/finance` | Dashboard provisioning |
| `./grafana/provisioning/datasources` | `/etc/grafana/provisioning/datasources/finance` | Datasource provisioning |

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `LOGIN failed` on IMAP | Microsoft disabled Basic Auth for personal accounts — use Graph API (this setup) |
| `400 Bad Request` on device code | Enable **Allow public client flows** in Azure → Authentication → Settings |
| `Token refresh failed: 400` | Use `tenant_id: "consumers"` in `config.json`, not the directory tenant ID |
| `No module named 'bs4'` | Rebuild with `docker compose build --no-cache itau-tracker` |
| Token expired after 90 days | Re-run `docker exec -it itau-tracker python /app/auth.py` |
| Dashboard shows no data | Verify datasource UID matches `finance_dashboard.json` — update with `sed` command |
| Dashboard in wrong Grafana folder | Check `grafana/provisioning/dashboards/finance.yaml` has correct `folder: Finance` |
| `card:None` in logs | Rebuild after regex fix — `docker compose build --no-cache itau-tracker` |
