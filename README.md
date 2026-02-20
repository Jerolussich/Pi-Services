# Pi Services

A collection of self-hosted services running on a Raspberry Pi 5, managed with Docker Compose. Covers network ad-blocking, system monitoring, Fitbit health data export, a full news reading pipeline, and automatic credit card expense tracking.

---

## Architecture

```
Raspberry Pi 5
│
├── caddy           → Reverse proxy, single entry point (port 80)
├── homepage        → Unified dashboard (homepage.pi)
├── monitoring      → Prometheus + Grafana + exporters (grafana.pi, prometheus.pi)
├── fitbit-exporter → Monthly export container (no port, writes to SQLite)
├── news/
│   ├── freshrss        → RSS feed aggregator (freshrss.pi)
│   ├── wallabag        → Article reader (wallabag.pi)
│   ├── news-filter     → Daily keyword filter (no port, cron)
│   └── news-filter-ui  → Keywords UI + run logs (news.pi)
└── finance/
    ├── itau-tracker    → Hourly email fetch + parse (no port, cron)
    └── itau-tracker-ui → Expense dashboard + config UI (finance.pi)
```

All services run as Docker containers on a shared `pi-services` network. None expose host ports directly — all traffic goes through Caddy on port 80. Pi-hole provides local DNS resolution for `*.pi` hostnames.

---

## Services

### Caddy
**Image:** `caddy:2-alpine`  
**Port:** `80`  
Reverse proxy that routes all incoming traffic to the correct container based on the hostname. Provides HTTP Basic Auth for services without their own authentication (Homepage, Prometheus). All other containers have no exposed host ports — Caddy is the only entry point.

### Homepage
**Image:** `ghcr.io/gethomepage/homepage:latest`  
A dashboard that links to all services. Config lives in `homepage/config/` and is bind-mounted into the container. Accessible via `http://homepage.pi` — protected by Caddy Basic Auth.

### Monitoring
**Images:** `prom/prometheus`, `prom/node-exporter`, `ekofr/pihole-exporter`, `grafana/grafana-oss`  
Prometheus scrapes system and Pi-hole metrics. Grafana visualizes them and also connects to the Fitbit and Finance SQLite databases. Accessible via `http://grafana.pi` and `http://prometheus.pi` — Prometheus is protected by Caddy Basic Auth.

### Fitbit Exporter
**Image:** built from `fitbit-exporter/Dockerfile`  
Runs a cron job inside a container on the 1st of every month at 6am. Fetches the previous month's data from the Fitbit API and exports it to `exports/fitbit_data.xlsx` and `exports/fitbit.db` (SQLite). `tokens.json` and `exports/` are bind-mounted from the host. Grafana reads from the SQLite file for health dashboards.

### FreshRSS
**Image:** `freshrss/freshrss:latest`  
RSS feed aggregator. Fetches full article content via CSS scraping and exposes articles via the Google Reader API for `news-filter` to consume. Accessible via `http://freshrss.pi`.

### Wallabag
**Image:** `wallabag/wallabag`  
Clean article reading without ads or account barriers. Used by `news-filter` as both a scraper fallback and final article storage. Data persists in a named Docker volume. Accessible via `http://wallabag.pi`.

### News Filter
**Image:** built from `news/news-filter/Dockerfile`  
Daily cron at 8am. Reads articles from FreshRSS, checks them against a keyword list, and saves matches to Wallabag. Uses SQLite (`seen.db`) for deduplication. Falls back to Wallabag's scraper for short/truncated content. Automatically cleans up old entries from both `seen.db` and Wallabag based on retention settings.

### News Filter UI
**Image:** built from `news/news-filter/ui/Dockerfile`  
Lightweight Flask web UI for managing keywords, viewing run logs, pausing/resuming the cron, and resetting all news data. Protected with HTTP Basic Auth. Accessible via `http://news.pi`.

### Itaú Tracker
**Image:** built from `finance/itau-tracker/tracker/Dockerfile`  
Hourly cron. Reads Itaú purchase notification emails from a Hotmail account via the Microsoft Graph API, parses transaction details (card, amount, currency, merchant), auto-categorizes by keyword matching, and stores results in SQLite (`finance.db`).

### Itaú Tracker UI
**Image:** built from `finance/itau-tracker/ui/Dockerfile`  
Flask web UI for viewing recent transactions, monthly spending charts, category breakdowns, editing categories and credentials, triggering manual runs with live log, and pausing/resuming the cron. Protected with HTTP Basic Auth. Accessible via `http://finance.pi`.

---

## Stack

| Tool | Purpose |
|---|---|
| Docker + Docker Compose | Container orchestration |
| Caddy | Reverse proxy + Basic Auth |
| Pi-hole | Network-wide ad blocking + local DNS |
| Prometheus | Metrics collection |
| Grafana | Visualization |
| Node Exporter | System metrics (CPU, RAM, disk) |
| Pi-hole Exporter | Pi-hole metrics for Grafana |
| Homepage | Service dashboard |
| FreshRSS | RSS feed aggregator |
| Wallabag | Article reader and scraper |
| Flask | News filter UI + Finance tracker UI |
| Python 3 + Docker | Fitbit export + news filter + finance tracker (containerized) |
| SQLite | Fitbit data + news deduplication + finance transactions |
| Cron | Monthly Fitbit export + daily news filter + hourly finance fetch |
| Microsoft Graph API | Email reading for finance tracker |

---

## Directory Structure

```
pi-services/
├── docker-compose.yml              ← Root: includes all services
├── .gitignore
│
├── caddy/
│   ├── docker-compose.yml
│   ├── Caddyfile                   ← Route rules for all services
│   ├── .env                        ← gitignored (CADDY_USER, CADDY_PASSWORD_HASH)
│   └── .env.example
│
├── homepage/
│   ├── docker-compose.yml
│   ├── .env                        ← gitignored
│   ├── .env.example
│   └── config/                     ← Bind-mounted into container
│       ├── bookmarks.yaml
│       ├── services.yaml
│       ├── settings.yaml
│       ├── widgets.yaml
│       └── ...
│
├── monitoring/
│   ├── docker-compose.yml
│   ├── .env                        ← gitignored
│   ├── .env.example
│   ├── prometheus.yml
│   └── grafana/
│       ├── dashboards/
│       │   ├── fitbit/             ← Fitbit dashboards
│       │   │   ├── fitbit_dashboard.json
│       │   │   └── fitbit_insights_dashboard.json
│       │   └── finance/            ← Finance dashboards
│       │       └── finance_dashboard.json
│       └── provisioning/
│           ├── dashboards/
│           │   └── fitbit.yaml     ← Providers for both Fitbit and Finance folders
│           └── datasources/
│               └── finance.yaml
│
├── fitbit-exporter/
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── export.py
│   ├── requirements.txt
│   ├── gather_keys_oauth2.py
│   ├── tokens.json                 ← gitignored (credentials), bind-mounted
│   ├── tokens.json.example
│   ├── README.md
│   └── exports/                    ← gitignored (personal health data), bind-mounted
│
├── news/
│   ├── README.md
│   ├── freshrss/
│   │   ├── docker-compose.yml
│   │   └── .env.example
│   │
│   ├── wallabag/
│   │   ├── docker-compose.yml
│   │   ├── .env                    ← gitignored
│   │   └── .env.example
│   │
│   └── news-filter/
│       ├── docker-compose.yml      ← defines both news-filter AND news-filter-ui
│       ├── Dockerfile              ← cron container
│       ├── filter.py
│       ├── requirements.txt
│       ├── .env                    ← gitignored
│       ├── .env.example
│       ├── config/
│       │   └── keywords.txt
│       ├── data/                   ← gitignored
│       │   ├── seen.db
│       │   ├── filter.log
│       │   └── paused
│       └── ui/
│           ├── Dockerfile          ← Flask UI container
│           ├── app.py
│           ├── requirements.txt
│           ├── .env                ← gitignored (UI_USERNAME, UI_PASSWORD)
│           ├── .env.example
│           └── templates/
│               └── index.html
│
└── finance/
    └── itau-tracker/
        ├── docker-compose.yml      ← defines both itau-tracker AND itau-tracker-ui
        ├── .env                    ← gitignored (UI_USERNAME, UI_PASSWORD)
        ├── .env.example
        ├── tracker/
        │   ├── Dockerfile          ← cron container
        │   ├── fetch.py
        │   ├── auth.py             ← one-time OAuth2 setup
        │   └── requirements.txt
        ├── ui/
        │   ├── Dockerfile          ← Flask UI container
        │   ├── app.py
        │   ├── requirements.txt
        │   └── templates/
        │       └── index.html
        └── data/                   ← gitignored
            ├── finance.db
            ├── config.json         ← editable from UI
            ├── token.json          ← gitignored (OAuth2 tokens)
            ├── tracker.log
            └── paused
```

---

## Setup

### Prerequisites

- Raspberry Pi with Docker and Docker Compose installed
- Git
- Pi-hole running on the network for local DNS resolution

> Before starting, read the `README.md` for each service you plan to use. Some require external account setup or one-time authorization steps that must be completed before or after the containers start. In particular:
> - `caddy/README.md` — Pi-hole DNS records and port 80 setup must be done before Caddy starts
> - `fitbit-exporter/README.md` — requires a Fitbit developer account and OAuth2 token setup
> - `finance/itau-tracker/README.md` — requires a Microsoft Azure app registration and one-time device code authorization

### 1. Clone the repo

```bash
git clone git@github.com:Jerolussich/Pi-Services.git
cd Pi-Services
```

### 2. Configure environment files

Each service has a `.env.example`. Copy and fill in each one:

```bash
cp homepage/.env.example homepage/.env
cp monitoring/.env.example monitoring/.env
cp news/wallabag/.env.example news/wallabag/.env
cp news/news-filter/.env.example news/news-filter/.env
cp news/news-filter/ui/.env.example news/news-filter/ui/.env
cp finance/itau-tracker/.env.example finance/itau-tracker/.env
cp caddy/.env.example caddy/.env
```

**`homepage/.env`**
```
PI_IP=your_pi_ip
```

**`monitoring/.env`**
```
PIHOLE_PASSWORD=your_pihole_password
FITBIT_EXPORTS_PATH=/home/youruser/Pi-Services/fitbit-exporter/exports
FINANCE_DATA_PATH=/home/youruser/Pi-Services/finance/itau-tracker/data
```

**`news/wallabag/.env`**
```
PI_IP=your_pi_ip
```

**`news/news-filter/.env`**
```
FRESHRSS_URL=http://freshrss:80
FRESHRSS_USERNAME=admin
FRESHRSS_API_PASSWORD=your_freshrss_api_password
WALLABAG_URL=http://wallabag:80
WALLABAG_CLIENT_ID=your_client_id
WALLABAG_CLIENT_SECRET=your_client_secret
WALLABAG_USERNAME=wallabag
WALLABAG_PASSWORD=your_wallabag_password
EXTRA_KEYWORDS=
MIN_CONTENT_LENGTH=500
SEEN_RETENTION_DAYS=30
LOG_RETENTION_DAYS=90
```

**`finance/itau-tracker/.env`**
```
UI_USERNAME=admin
UI_PASSWORD=your_ui_password
```

**`caddy/.env`** — generate the password hash first:
```bash
docker run --rm caddy:2-alpine caddy hash-password --plaintext 'yourpassword'
```
Then escape every `$` as `$$` when putting it in the `.env` file:
```
CADDY_USER=admin
CADDY_PASSWORD_HASH=$$2a$$14$$your_bcrypt_hash_here
```

### 3. Set up Fitbit exporter

```bash
cp fitbit-exporter/tokens.json.example fitbit-exporter/tokens.json
mkdir -p fitbit-exporter/exports
```

Fill in your Fitbit credentials in `tokens.json`. Follow `fitbit-exporter/README.md` for the full OAuth2 setup.

### 4. Create news-filter data folders

```bash
mkdir -p news/news-filter/config
mkdir -p news/news-filter/data
cat > news/news-filter/config/keywords.txt << 'EOF'
artificial intelligence
machine learning
openai
anthropic
EOF
```

### 5. Start all services

```bash
docker compose up -d
```

### 6. First-time service configuration

- **Pi-hole DNS** — add local DNS records for all `*.pi` hostnames pointing to your Pi's IP in Pi-hole admin → **Local DNS → DNS Records**
- **FreshRSS** (`http://freshrss.pi`) — complete the install wizard, enable API access in **Settings → Authentication**, set API password in **Settings → Profile**, set archiving to 30 days in **Settings → Archiving**
- **Wallabag** (`http://wallabag.pi`) — login with `wallabag / wallabag`, change password, create API client in **API clients management**, add credentials to `news/news-filter/.env`
- **Grafana** (`http://grafana.pi`) — login with `admin / admin`, change password, install SQLite plugin, configure Fitbit and Finance datasources
- **Itaú Tracker** — run one-time authorization: `docker exec -it itau-tracker python /app/auth.py`, follow the device code flow in your browser, then run the first fetch: `docker exec itau-tracker python /app/fetch.py`

See each service's `README.md` for detailed setup instructions.

### 7. Verify

```bash
docker compose ps
```

All containers should show `Up`.

---

## Managing Services

| Action | Command |
|---|---|
| Start everything | `docker compose up -d` |
| Stop everything | `docker compose down` |
| Restart one service | `docker compose up -d --force-recreate <service>` |
| Rebuild after code change | `docker compose up -d --build <service>` |
| View logs | `docker logs <container_name>` |
| View all status | `docker compose ps` |

---

## Access

| Service | URL | Auth |
|---|---|---|
| Homepage | `http://homepage.pi` | Caddy Basic Auth |
| Grafana | `http://grafana.pi` | Grafana login |
| FreshRSS | `http://freshrss.pi` | FreshRSS login |
| Wallabag | `http://wallabag.pi` | Wallabag login |
| News Filter UI | `http://news.pi` | Flask Basic Auth |
| Itaú Tracker UI | `http://finance.pi` | Flask Basic Auth |
| Prometheus | `http://prometheus.pi` | Caddy Basic Auth |
| Pi-hole | `http://pihole.pi/admin` | Pi-hole login |

---

## Security Notes

- `tokens.json` contains live Fitbit OAuth2 credentials — never commit it
- `data/token.json` contains live Microsoft OAuth2 tokens — never commit it
- `.env` files contain passwords — never commit them
- `data/config.json` in itau-tracker contains the Azure client secret — never commit it
- `caddy/password.hash` if used — never commit it
- All sensitive files are covered by `.gitignore`
- Use `.env.example` files as templates when setting up on a new machine
- Wallabag default credentials are `wallabag / wallabag` — change them after first login
- FreshRSS API password is separate from the login password — set it in **Settings → Profile**
- The bcrypt hash in `caddy/.env` cannot be reversed, but keeping it private prevents offline brute force attacks
- All services are only reachable through Caddy — no container exposes host ports directly except Caddy on port 80
- Pi-hole web interface runs on port 8181 (not 80) to free port 80 for Caddy

---

## Further Documentation

Each service has its own `README.md` with detailed setup, technical details, and troubleshooting:

- `caddy/README.md`
- `homepage/README.md`
- `monitoring/README.md`
- `fitbit-exporter/README.md`
- `news/README.md`
- `finance/itau-tracker/README.md`
