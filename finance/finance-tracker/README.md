# Finance Tracker

Tracks movements across bank accounts from two sources:

1. **Emails (Itaú-only)** — Itaú credit-card purchase notifications fetched hourly from a Hotmail/Outlook account via the Microsoft Graph API. The email regex is Itaú-specific — other banks would need their own tracker.
2. **PDF statements (bank-pluggable)** — full account statements uploaded from the web UI. The user picks the bank in the upload form; the UI dispatches to the right parser via a small registry (`ui/parsers/__init__.py`). Currently only Itaú is implemented; adding a new bank (Santander, BROU, …) is a new file in `ui/parsers/` plus one line in `_MODULES`.

All movements land in the same SQLite table, are categorized, and are visualized in Grafana.

---

## Architecture

```
Microsoft Graph API                PDF statement (user upload + bank picker)
        ↓ (hourly cron)                      ↓
  itau-email-tracker (fetch.py)    finance-tracker-ui (/upload, parsers/<bank>.py)
        ↓                                    ↓
                        finance.db (SQLite)
                                ↓
                  finance-tracker-ui (Flask dashboard)
                  Grafana via SQLite datasource
```

Both containers are defined in a single `docker-compose.yml` and share a `data/` bind mount.

The Grafana dashboard and provisioning live in `monitoring/grafana/` alongside the Fitbit dashboards — Grafana is managed entirely from the monitoring service.

---

## Directory Structure

```
finance/
└── finance-tracker/
    ├── docker-compose.yml
    ├── .env                        ← gitignored (UI_USERNAME, UI_PASSWORD, SECRET_KEY)
    ├── .env.example
    ├── tracker/
    │   ├── Dockerfile
    │   ├── fetch.py                ← Itaú email fetcher (Graph API)
    │   ├── auth.py
    │   └── requirements.txt
    ├── ui/
    │   ├── Dockerfile            ← installs poppler-utils for pdftotext
    │   ├── app.py
    │   ├── parsers/
    │   │   ├── __init__.py       ← parser registry (BANKS, get_parser)
    │   │   ├── base.py           ← BankMismatchError
    │   │   └── itau.py           ← Itaú statement PDF parser
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
2. Click **New registration** — name: `itau-email-tracker`, personal accounts only
3. Go to **Manage → Authentication** → enable **Allow public client flows** → Save
4. Go to **Manage → API permissions** → Microsoft Graph → Delegated → `Mail.Read` → Grant admin consent
5. Go to **Manage → Certificates & secrets** → New client secret → copy the **Value** immediately
6. Note your **Application (client) ID** from the Overview page

### 2. Configure .env

```bash
cp finance/finance-tracker/.env.example finance/finance-tracker/.env
```

**`finance/finance-tracker/.env`**
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
mkdir -p finance/finance-tracker/data

cat > finance/finance-tracker/data/config.json << 'EOF'
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
    "entretenimiento": ["cinema", "movie", "teatro", "tickantel", "antel arena"],
    "transferencia": ["traspaso", "transferencia"],
    "conversion": ["cambio", "cambios", "conversion"],
    "facturas": ["factura", "pago factura"]
  }
}
EOF
```

### 4. Add finance path to monitoring/.env

```bash
echo "FINANCE_DATA_PATH=/home/youruser/pi-services/finance/finance-tracker/data" >> monitoring/.env
```

### 5. Build and start containers

```bash
docker compose up -d --build itau-email-tracker finance-tracker-ui
```

### 6. One-time authorization

```bash
docker exec -it itau-email-tracker python /app/auth.py
```

Open the printed URL, enter the code, sign in with your Hotmail account. `data/token.json` is saved automatically.

### 7. Run first fetch

```bash
docker exec itau-email-tracker python /app/fetch.py
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

### PDF upload flow (drag & drop)

1. User goes to the **Upload PDF** tab in the UI.
2. Picks a **Bank** from the dropdown. The list is built from `parsers.BANKS` — only banks with a parser appear. Uploading a PDF while picking a bank that has no parser returns a flash error.
3. Enters an **Account name** (required — e.g. `Itaú UYU`, `Itaú USD`). The name identifies the source: reuse the same name for subsequent statements of the same account, or pick a new name for a different account of the same bank.
4. Drops a statement PDF (or clicks to browse). Max 10 MB, `.pdf` only.
5. `app.py` resolves the parser via `get_parser(bank)` and calls `parser.parse_pdf(path, account=…)`. Each parser first validates the PDF matches its bank — if not, it raises `BankMismatchError` and the user sees a clear error instead of a silent "0 imported" (e.g. uploading a Santander PDF while Itaú is selected).
6. The Itaú parser (`parsers/itau.py`) runs `pdftotext -layout` (via `poppler-utils` baked into the UI container) and parses every transaction line across all pages:
   - Currency detected from page header (`URGP` → `UYU`, `US.D` → `USD`).
   - Statement date parsed from the page header → year assigned to each `DDMMM` row (December rows in a January statement get rolled back a year).
   - Debit vs credit determined by the horizontal position of the amount on the line.
   - Opening/closing balance rows (`SDO.APERTURA`, `SDO. CIERRE`) are skipped.
   - Each row gets a deterministic external id (`pdf:<sha1 of account|date|currency|type|merchant|amount|n>`) so re-uploading the same PDF is idempotent.
7. Merchants are categorized with the same keyword map as the email flow.
8. Insert summary is flashed back on the page (imported / duplicates / total rows in the PDF).

#### Adding a new bank parser

1. Create `ui/parsers/<bank>.py` exposing `BANK_ID`, `BANK_LABEL`, and `parse_pdf(pdf_path, account="") -> list[dict]`.
2. Inside `parse_pdf`, detect the bank's markers early and raise `BankMismatchError` if the PDF doesn't match.
3. Add the module to `_MODULES` in `ui/parsers/__init__.py`.
4. Rebuild the UI container. The bank appears in the dropdown automatically.

### finance.db Schema

```sql
CREATE TABLE transactions (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    email_id      TEXT UNIQUE,           -- email Graph id for emails, "pdf:<hash>" for PDFs
    date          TEXT,
    card_type     TEXT,                  -- card brand for emails; NULL for PDFs
    card_last4    TEXT,                  -- last 4 digits for emails; NULL for PDFs
    amount        REAL,                  -- always positive
    currency      TEXT,                  -- 'UYU' | 'USD'
    merchant      TEXT,                  -- merchant (emails) or description (PDFs)
    category      TEXT,                  -- keyword-based category
    source        TEXT DEFAULT 'email',  -- 'email' | 'pdf'
    direction     TEXT DEFAULT 'debit',  -- 'debit' (outflow) | 'credit' (inflow)
    movement_type TEXT,                  -- 'CONSUMO' for emails; 'COMPRA' / 'TRASPASO DE' / … for PDFs
    account       TEXT                   -- user-provided account label (e.g. 'Itaú UYU'); 'Itaú tarjeta (email)' for emails
);
```

Existing databases are migrated in place on first run (new columns added via `ALTER TABLE … IF NOT EXISTS`-style guards in both `fetch.py` and `app.py`).

---

## finance-tracker-ui

Flask web UI at `http://finance.pi`. Protected with HTTP Basic Auth via `UI_USERNAME` / `UI_PASSWORD`.

### Security

CSRF protection (`flask-wtf`) and rate limiting (`flask-limiter`) are enabled on all POST endpoints:

| Endpoint | Limit |
|---|---|
| `/run` | 5/min |
| `/toggle-pause` | 10/min |
| `/config` POST | 10/min |
| `/upload` POST | 10/min |
| `/reset` | 3/min |
| `/log` | exempt (GET, used by live polling) |

Upload body size is capped at **10 MB** via `MAX_CONTENT_LENGTH`.

All forms include a CSRF token — POST requests without a valid token + session cookie are rejected with `400`. IPs exceeding the rate limit receive `429`.

### Features

**Dashboard tab** — gastos/ingresos/total of the month, monthly bar chart, category chart, **by-account summary** (in/out/net per account & currency), recent movements table with direction (↑/↓) and source/account, live run log.

**Upload PDF tab** — drag & drop (or browse) an account-statement PDF. Pick the **Bank** from the dropdown (today: Itaú) and an **Account** label so statements from different accounts stay separate. Shows the list of known accounts below the drop zone (auto-completed in the input). Re-uploading the same PDF is a no-op (duplicates are skipped). If the PDF doesn't match the selected bank, the upload is rejected with an explicit error.

**Config tab** — edit Azure credentials, sender filter, and category keyword lists. Changes saved to `data/config.json` without rebuild.

**Header controls** — **▶ Run now** triggers fetch immediately with live log. **⏸ Pause / ▶ Resume** pauses/resumes the hourly cron.

**Danger Zone** — **🗑 Delete all data** clears all transactions and the log.

---

## Grafana Dashboards

Lives in `monitoring/grafana/dashboards/finance/`, provisioned automatically. Reads from `finance.db` via the Finance SQLite datasource at `/var/finance/finance.db`.

The dashboard is organized in rows that match the data model:

| Row | What it shows |
|---|---|
| **📅 This Month (UYU)** | Gastos, ingresos, neto del mes, cantidad de movimientos |
| **📈 Trends** | Mensual gastos-vs-ingresos (bar chart) + torta de categorías del mes |
| **🏦 By Account** | Tabla resumen por cuenta (ingresos / gastos / neto) + gastos mensuales apilados por cuenta |
| **💵 USD** | Stats y serie mensual en dólares |
| **🔝 Top movers (este mes)** | Top comercios en gastos y en ingresos |
| **📊 All Time (UYU)** | Gastos por categoría y top comercios de siempre |
| **🧾 Recent Transactions** | Últimos 40 movimientos con cuenta, tipo, dirección y monto signado |

Queries filter by `direction = 'debit'` for expense charts and `direction = 'credit'` for income charts; the by-account table combines both. Panels automatically pick up new data uploaded via **Upload PDF**.

---

## Volumes

| Path (host) | Path (container) | Service |
|---|---|---|
| `./data` | `/app/data` | tracker + ui |
| `./tracker/fetch.py` | `/app/fetch.py` | ui (for Run now) |
| `finance/finance-tracker/data` | `/var/finance` | grafana (read-only) |

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `400 Bad Request` on device code | Enable **Allow public client flows** in Azure → Authentication |
| `Token refresh failed: 400` | Use `"tenant_id": "consumers"` in `config.json` |
| `card:None` in logs | Rebuild after regex fix |
| Token expired after 90 days | Re-run `docker exec -it itau-email-tracker python /app/auth.py` |
| Dashboard shows no data | Verify datasource UID matches — update with `sed` |
| UI returns 400 on form submit | CSRF token missing — browser submits automatically, curl requires session cookie |
| UI returns 429 | Rate limit hit — wait 1 minute |
