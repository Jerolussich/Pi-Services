# Pi Services

A collection of self-hosted services running on a Raspberry Pi 5, managed with Docker Compose. Covers network ad-blocking, system monitoring, Fitbit health data export, and a full news reading pipeline.

---

## Architecture

```
Raspberry Pi 5
│
├── homepage        → Unified dashboard (port 3001)
├── monitoring      → Prometheus + Grafana + exporters (port 3000)
├── fitbit-exporter → Monthly export container (no port, writes to SQLite)
└── news/
    ├── freshrss        → RSS feed aggregator (port 8083)
    ├── wallabag        → Article reader (port 8082)
    ├── news-filter     → Daily keyword filter (no port, cron)
    └── news-filter-ui  → Keywords UI + run logs (port 8084)
```

All services run as Docker containers and are managed from a single root `docker-compose.yml`.

---

## Services

### Homepage
**Image:** `ghcr.io/gethomepage/homepage:latest`  
**Port:** `3001`  
A dashboard that links to all services. Config lives in `homepage/config/` and is bind-mounted into the container.

### Monitoring
**Images:** `prom/prometheus`, `prom/node-exporter`, `ekofr/pihole-exporter`, `grafana/grafana-oss`  
**Ports:** `9090` (Prometheus), `9100` (Node Exporter), `9617` (Pi-hole Exporter), `3000` (Grafana)  
Prometheus scrapes system and Pi-hole metrics. Grafana visualizes them and also connects to the Fitbit SQLite database for health dashboards.

### Fitbit Exporter
**Image:** built from `fitbit-exporter/Dockerfile`  
Runs a cron job inside a container on the 1st of every month at 6am. Fetches the previous month's data from the Fitbit API and exports it to `exports/fitbit_data.xlsx` and `exports/fitbit.db` (SQLite). `tokens.json` and `exports/` are bind-mounted from the host. Grafana reads from the SQLite file for health dashboards.

### FreshRSS
**Image:** `freshrss/freshrss:latest`  
**Port:** `8083`  
RSS feed aggregator. Fetches full article content via CSS scraping and exposes articles via the Google Reader API for `news-filter` to consume.

### Wallabag
**Image:** `wallabag/wallabag`  
**Port:** `8082`  
Clean article reading without ads or account barriers. Used by `news-filter` as both a scraper fallback and final article storage. Data persists in a named Docker volume.

### News Filter
**Image:** built from `news/news-filter/Dockerfile`  
Daily cron at 8am. Reads articles from FreshRSS, checks them against a keyword list, and saves matches to Wallabag. Uses SQLite (`seen.db`) for deduplication. Falls back to Wallabag's scraper for short/truncated content. Automatically cleans up old entries from both `seen.db` and Wallabag based on retention settings.

### News Filter UI
**Image:** built from `news/news-filter-ui/Dockerfile`  
**Port:** `8084`  
Lightweight Flask web UI for managing keywords, viewing run logs, pausing/resuming the cron, and resetting all news data.

---

## Stack

| Tool | Purpose |
|---|---|
| Docker + Docker Compose | Container orchestration |
| Prometheus | Metrics collection |
| Grafana | Visualization |
| Node Exporter | System metrics (CPU, RAM, disk) |
| Pi-hole Exporter | Pi-hole metrics for Grafana |
| Homepage | Service dashboard |
| FreshRSS | RSS feed aggregator |
| Wallabag | Article reader and scraper |
| Flask | News filter web UI |
| Python 3 + Docker | Fitbit export + news filter (containerized) |
| SQLite | Fitbit data storage + news deduplication |
| Cron | Monthly Fitbit export + daily news filter |

---

## Directory Structure

```
pi-services/
├── docker-compose.yml              ← Root: lifts all services
├── .gitignore
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
│       │   ├── fitbit_dashboard.json
│       │   └── fitbit_insights_dashboard.json
│       └── provisioning/
│           └── dashboards/
│               └── fitbit.yaml
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
└── news/
    ├── README.md
    ├── freshrss/
    │   ├── docker-compose.yml
    │   └── .env.example
    │
    ├── wallabag/
    │   ├── docker-compose.yml
    │   ├── .env                    ← gitignored
    │   └── .env.example
    │
    ├── news-filter/
    │   ├── Dockerfile
    │   ├── docker-compose.yml
    │   ├── filter.py
    │   ├── requirements.txt
    │   ├── .env                    ← gitignored
    │   ├── .env.example
    │   ├── config/
    │   │   └── keywords.txt        ← editar directo o via UI
    │   └── data/                   ← gitignored
    │       ├── seen.db
    │       ├── filter.log
    │       └── paused              ← centinela para pausar el cron
    │
    └── news-filter-ui/
        ├── Dockerfile
        ├── docker-compose.yml
        ├── app.py
        ├── requirements.txt
        └── templates/
            └── index.html
```

---

## Setup

### Prerequisites

- Raspberry Pi with Docker and Docker Compose installed
- Git
- A Fitbit developer account (for fitbit-exporter)

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
```

**`homepage/.env`**
```
PI_IP=your_pi_ip
```

**`monitoring/.env`**
```
PIHOLE_PASSWORD=your_pihole_password
FITBIT_EXPORTS_PATH=/home/youruser/Pi-Services/fitbit-exporter/exports
```

**`news/wallabag/.env`**
```
PI_IP=your_pi_ip
```

**`news/news-filter/.env`**
```
FRESHRSS_URL=http://your_pi_ip:8083
FRESHRSS_USERNAME=admin
FRESHRSS_API_PASSWORD=your_freshrss_api_password
WALLABAG_URL=http://your_pi_ip:8082
WALLABAG_CLIENT_ID=your_client_id
WALLABAG_CLIENT_SECRET=your_client_secret
WALLABAG_USERNAME=wallabag
WALLABAG_PASSWORD=your_wallabag_password
EXTRA_KEYWORDS=
MIN_CONTENT_LENGTH=500
SEEN_RETENTION_DAYS=30
LOG_RETENTION_DAYS=90
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

- **FreshRSS** (`http://<pi_ip>:8083`) — complete the install wizard, enable API access in **Settings → Authentication**, set API password in **Settings → Profile**, set archiving to 30 days in **Settings → Archiving**
- **Wallabag** (`http://<pi_ip>:8082`) — login with `wallabag / wallabag`, change password, create API client in **API clients management**, add credentials to `news/news-filter/.env`
- **Grafana** (`http://<pi_ip>:3000`) — login with `admin / admin`, change password, install SQLite plugin, configure Fitbit datasource

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

| Service | URL | Description |
|---|---|---|
| Homepage | `http://<pi_ip>:3001` | Unified dashboard |
| Grafana | `http://<pi_ip>:3000` | Metrics + Fitbit dashboards |
| FreshRSS | `http://<pi_ip>:8083` | RSS feed reader |
| Wallabag | `http://<pi_ip>:8082` | Saved articles |
| News Filter UI | `http://<pi_ip>:8084` | Manage keywords + logs |
| Prometheus | `http://<pi_ip>:9090` | Raw metrics |

---

## Security Notes

- `tokens.json` contains live Fitbit OAuth2 credentials — never commit it
- `.env` files contain passwords — never commit them
- All sensitive files are covered by `.gitignore`
- Use `.env.example` files as templates when setting up on a new machine
- Wallabag default credentials are `wallabag / wallabag` — change them after first login
- FreshRSS API password is separate from the login password — set it in **Settings → Profile**

---

## Further Documentation

Each service has its own `README.md` with detailed setup, technical details, and troubleshooting:

- `homepage/README.md`
- `monitoring/README.md`
- `fitbit-exporter/README.md`
- `news/README.md`
