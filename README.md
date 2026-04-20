# Pi Services

A collection of self-hosted services running on a Raspberry Pi 5, mostly managed with Docker Compose. Covers network ad-blocking, system monitoring, Fitbit health data export, a full news reading pipeline, automatic credit card expense tracking, and a personal e-book library.

---

## Architecture

```
Raspberry Pi 5
│
├── caddy           → Reverse proxy, single entry point (port 80)
├── homepage        → Unified dashboard (homepage.pi)
├── monitoring      → Prometheus + Grafana + exporters (grafana.pi, prometheus.pi)
├── fitbit-exporter      → Monthly export container (no port, writes to SQLite)
├── fitbit-exporter-ui   → Flask UI for manual per-month ingest (fitbit.pi)
├── news/
│   ├── freshrss        → RSS feed aggregator (freshrss.pi)
│   ├── wallabag        → Article reader (wallabag.pi)
│   ├── news-filter     → Daily keyword filter (no port, scheduled by Ofelia)
│   └── news-filter-ui  → Keywords UI + run logs (news.pi)
├── ofelia          → Centralized cron scheduler
├── ofelia/
│   ├── docker-compose.yml
│   └── README.md
│
├── finance/
│   ├── itau-tracker    → Hourly email fetch + parse (no port, scheduled by Ofelia)
│   └── itau-tracker-ui → Expense dashboard + config UI (finance.pi)
│
└── calibre         → E-book library server (native, NOT Docker — calibre.pi)
```

Almost all services run as Docker containers on a shared `pi-services` network and are reached through Caddy on port 80. The exception is **Calibre**, which runs natively on the host (systemd user-service) for faster recovery after power outages; Caddy still reverse-proxies it at `calibre.pi`. Pi-hole provides local DNS resolution for `*.pi` hostnames.

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
**Images:** `prom/prometheus`, `prom/node-exporter`, `amonacoos/pihole6_exporter`, `grafana/grafana-oss`
Prometheus scrapes system and Pi-hole metrics. Grafana visualizes them and also connects to the Fitbit and Finance SQLite databases. Accessible via `http://grafana.pi` and `http://prometheus.pi` — Prometheus is protected by Caddy Basic Auth.

### Fitbit Exporter
**Image:** built from `fitbit-exporter/Dockerfile`
Runs on the 1st of every month at 6am, scheduled by Ofelia (`python /app/export.py --source scheduled`). Fetches the previous month's data from the Fitbit API and exports it to `exports/fitbit_data.xlsx` and `exports/fitbit.db` (SQLite). `export.py` also accepts `--year/--month` so any month can be backfilled on demand. Every run writes a row to the `ingest_runs` table (status + source + timestamps). `tokens.json` and `exports/` are bind-mounted from the host; Grafana reads from the SQLite file for health dashboards.

### Fitbit Exporter UI
**Image:** built from `fitbit-exporter/ui/Dockerfile`
Flask web UI for manual Fitbit ingest. Shows an 18-month grid with traffic-light status per month (green = all 4 data tables populated, orange = partial, gray = empty), overlaid with the last run's timestamp/source/status from `ingest_runs`. A date picker dispatches `python /app/export.py --year Y --month M --source manual` via `subprocess.Popen` — useful for backfilling months when the Pi was down on the 1st. Shares the `exports/` volume with the main exporter and mounts `export.py` read-only, so there is no code duplication. Protected with HTTP Basic Auth. Accessible via `http://fitbit.pi`.

### FreshRSS
**Image:** `freshrss/freshrss:latest`
RSS feed aggregator. Fetches full article content via CSS scraping and exposes articles via the Google Reader API for `news-filter` to consume. Accessible via `http://freshrss.pi`.

### Wallabag
**Image:** `wallabag/wallabag`
Clean article reading without ads or account barriers. Used by `news-filter` as both a scraper fallback and final article storage. Data persists in a named Docker volume. Accessible via `http://wallabag.pi`.

### News Filter
**Image:** built from `news/news-filter/Dockerfile`
Runs daily at 8am, scheduled by Ofelia. Reads articles from FreshRSS, checks them against a keyword list, and saves matches to Wallabag. Uses SQLite (`seen.db`) for deduplication. Falls back to Wallabag's scraper for short/truncated content. Automatically cleans up old entries from both `seen.db` and Wallabag based on retention settings.

### News Filter UI
**Image:** built from `news/news-filter/ui/Dockerfile`
Lightweight Flask web UI for managing keywords, viewing run logs, pausing/resuming the cron, and resetting all news data. Protected with HTTP Basic Auth. Accessible via `http://news.pi`.

### Itaú Tracker
**Image:** built from `finance/itau-tracker/tracker/Dockerfile`
Runs hourly, scheduled by Ofelia. Reads Itaú purchase notification emails from a Hotmail account via the Microsoft Graph API, parses transaction details (card, amount, currency, merchant), auto-categorizes by keyword matching, and stores results in SQLite (`finance.db`).

### Itaú Tracker UI
**Image:** built from `finance/itau-tracker/ui/Dockerfile`
Flask web UI for viewing recent transactions, monthly spending charts, category breakdowns, editing categories and credentials, triggering manual runs with live log, and pausing/resuming the cron. Protected with HTTP Basic Auth. Accessible via `http://finance.pi`.

### Ofelia
**Image:** `mcuadros/ofelia:latest`
Centralized cron scheduler for Docker containers. Replaces individual cron daemons inside containers. Schedules are defined as labels in each service's `docker-compose.yml`. Ofelia uses `docker exec` to run jobs, so environment variables are always available to the script. If a target container is stopped, Ofelia logs the failure and retries on the next schedule without affecting other jobs.

### Calibre
**Install:** native (apt) — NOT Docker
Personal e-book library and distribution hub. `calibre-server` runs as a systemd user-service on port 8083 with `--enable-local-write`, serves the library via web UI and OPDS, and survives power outages via systemd linger (no Docker daemon in the startup chain). Book discovery and downloads happen in **Calibre Desktop on the laptop** (using the built-in "Get Books" feature with free sources: Project Gutenberg, Internet Archive, Feedbooks, etc.). Bulk book ingest is done via `~/calibre-inbox/`: a user systemd timer runs every minute, calls `calibre-ingest` which uses `calibredb add` against the running server to import books with automatic deduplication (matches by title+author), deletes successful files, and moves failed ones to `failed/`. Caddy reverse-proxies the host service at `calibre.pi` with Basic Auth. See `calibre/README.md` for install, OPDS feeds and plugins.

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
| Pi-hole Exporter | Pi-hole metrics for Grafana (amonacoos/pihole6_exporter) |
| Homepage | Service dashboard |
| FreshRSS | RSS feed aggregator |
| Wallabag | Article reader and scraper |
| Flask | News filter UI + Finance tracker UI + Fitbit ingest UI |
| Python 3 + Docker | Fitbit export + news filter + finance tracker (containerized) |
| SQLite | Fitbit data + news deduplication + finance transactions |
| Ofelia | Centralized cron scheduler — manages fitbit-exporter, news-filter, itau-tracker |
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
│       │   ├── fitbit/
│       │   │   ├── fitbit_dashboard.json
│       │   │   └── fitbit_insights_dashboard.json
│       │   ├── finance/
│       │   │   └── finance_dashboard.json
│       │   └── pihole/
│       │       └── pihole_dashboard.json
│       └── provisioning/
│           └── dashboards/
│               └── dashboards.yaml ← Providers for Fitbit, Finance and Pihole folders
│
├── fitbit-exporter/
│   ├── Dockerfile                  ← main exporter (sleep infinity, run by Ofelia)
│   ├── docker-compose.yml          ← defines both fitbit-exporter AND fitbit-exporter-ui
│   ├── export.py                   ← --year/--month/--source CLI; writes to ingest_runs
│   ├── requirements.txt
│   ├── gather_keys_oauth2.py
│   ├── tokens.json                 ← gitignored (credentials), bind-mounted
│   ├── tokens.json.example
│   ├── README.md
│   ├── exports/                    ← gitignored (personal health data), bind-mounted
│   ├── data/                       ← gitignored (UI log target)
│   └── ui/
│       ├── Dockerfile              ← Flask UI container (gunicorn :8086)
│       ├── app.py                  ← /, /months, /ingest, /log
│       ├── requirements.txt
│       ├── .env                    ← gitignored (UI_USERNAME, UI_PASSWORD, SECRET_KEY)
│       ├── .env.example
│       └── templates/
│           └── index.html          ← month grid + picker + live log
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
│       ├── Dockerfile              ← sleep infinity (scheduled by Ofelia)
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
├── ofelia/
│   ├── docker-compose.yml
│   └── README.md
│
├── finance/
│   └── itau-tracker/
│       ├── docker-compose.yml      ← defines both itau-tracker AND itau-tracker-ui
│       ├── .env                    ← gitignored (UI_USERNAME, UI_PASSWORD)
│       ├── .env.example
│       ├── tracker/
│       │   ├── Dockerfile          ← sleep infinity (scheduled by Ofelia)
│       │   ├── fetch.py
│       │   ├── auth.py             ← one-time OAuth2 setup
│       │   └── requirements.txt
│       ├── ui/
│       │   ├── Dockerfile          ← Flask UI container
│       │   ├── app.py
│       │   ├── requirements.txt
│       │   └── templates/
│       │       └── index.html
│       └── data/                   ← gitignored
│           ├── finance.db
│           ├── config.json         ← editable from UI
│           ├── token.json          ← gitignored (OAuth2 tokens)
│           ├── tracker.log
│           └── paused
│
└── calibre/                        ← Native (apt install), NOT Docker
    ├── README.md
    ├── install.sh                  ← one-shot: apt + library + inbox + systemd + linger
    ├── bin/
    │   ├── calibre-ingest          ← processes ~/calibre-inbox with dedup (timer-driven)
    │   └── calibre-wipe            ← CLI: wipe entire library (with warnings)
    └── systemd/
        ├── calibre-server.service  ← user-service (port 8083 --enable-local-write)
        ├── calibre-ingest.service  ← oneshot triggered by the timer
        └── calibre-ingest.timer    ← runs calibre-ingest every minute
```

---

## Setup

### Prerequisites

- Raspberry Pi with Docker and Docker Compose installed
- Git
- Pi-hole running on the network for local DNS resolution

> Before starting, read the `README.md` for each service you plan to use. Some require external account setup or one-time authorization steps that must be completed before or after the containers start. In particular:
> - `caddy/README.md` — Pi-hole DNS records and port 80 setup must be done before Caddy starts
- `ofelia/README.md` — explains the centralized scheduler and how schedules are defined
- `fitbit-exporter/README.md` — requires a Fitbit developer account and OAuth2 token setup
- `finance/itau-tracker/README.md` — requires a Microsoft Azure app registration and one-time device code authorization

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
cp fitbit-exporter/ui/.env.example fitbit-exporter/ui/.env
cp caddy/.env.example caddy/.env
```

**`homepage/.env`**
```
PI_IP=your_pi_ip
```

**`monitoring/.env`**
```
PIHOLE_API_KEY=your_pihole_app_password
FITBIT_EXPORTS_PATH=/home/youruser/pi-services/fitbit-exporter/exports
FINANCE_DATA_PATH=/home/youruser/pi-services/finance/itau-tracker/data
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

**`fitbit-exporter/ui/.env`**
```
UI_USERNAME=admin
UI_PASSWORD=your_ui_password
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
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
| Fitbit Ingest UI | `http://fitbit.pi` | Flask Basic Auth |
| Calibre | `http://calibre.pi` | Caddy Basic Auth |
| Prometheus | `http://prometheus.pi` | Caddy Basic Auth |
| Pi-hole | `http://pihole.pi/admin` | Pi-hole login |

---

## Security

This setup follows a defense-in-depth approach for a local network deployment:

- **Reverse proxy** — Caddy is the single entry point on port 80. No service container exposes host ports directly
- **Authentication** — services without built-in auth are protected at the proxy level. Services with their own auth (Grafana, Wallabag, FreshRSS, Pi-hole) use their native login screens
- **Firewall** — UFW restricts inbound traffic to only the ports required for operation
- **Intrusion prevention** — fail2ban monitors logs and automatically blocks IPs with repeated failed authentication attempts
- **Reduced attack surface** — unused system services are disabled

### Security Setup Script

A setup script automates the full security configuration. It auto-detects running services and configures UFW and fail2ban without any manual port entry:

```bash
chmod +x setup-security.sh

# Preview what the script will do — no changes made
./setup-security.sh --dry-run

# Apply for real
./setup-security.sh
```

The `--dry-run` flag prints every command the script would execute without running any of them — use it to verify detected ports and planned changes before applying. The script detects all relevant ports from running services, offers to disable unused services (VNC, rpcbind), configures UFW allow/deny rules, installs and configures fail2ban with SSH and Caddy jails, and creates a stable symlink for the Caddy log so fail2ban survives container recreation. Re-run it any time you recreate the Caddy container.

### Sensitive Files

Sensitive files are covered by `.gitignore` and never committed. Use `.env.example` files as templates when setting up on a new machine.

- `tokens.json` — Fitbit OAuth2 credentials
- `finance/itau-tracker/data/token.json` — Microsoft OAuth2 tokens
- `finance/itau-tracker/data/config.json` — Azure client secret
- `caddy/.env` — Caddy Basic Auth credentials (bcrypt hash)
- All `**/.env` files — service passwords

---

## Further Documentation

Each service has its own `README.md` with detailed setup, technical details, and troubleshooting:

- `caddy/README.md`
- `ofelia/README.md`
- `homepage/README.md`
- `monitoring/README.md`
- `fitbit-exporter/README.md`
- `news/README.md`
- `finance/itau-tracker/README.md`
- `calibre/README.md`
