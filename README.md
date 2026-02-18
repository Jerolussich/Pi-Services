# Pi Services

A collection of self-hosted services running on a Raspberry Pi 5, managed with Docker Compose. Covers network ad-blocking, system monitoring, Fitbit health data export, article reading, and a unified dashboard.

---

## Architecture

```
Raspberry Pi 5
│
├── homepage        → Unified dashboard (port 3001)
├── monitoring      → Prometheus + Grafana + exporters (port 3000)
├── wallabag        → Article reader (port 8082)
├── fitbit-exporter → Monthly cron script (no port, writes to SQLite)
└── news            → Reserved for future use
```

All services (except fitbit-exporter) run as Docker containers and are managed from a single root `docker-compose.yml`.

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

### Wallabag
**Image:** `wallabag/wallabag`  
**Port:** `8082`  
Clean article reading without ads or account barriers. Data persists in a named Docker volume.

### Fitbit Exporter
**No container** — runs as a Python cron job.  
Every 1st of the month at 6am, it fetches the previous month's data from the Fitbit API and exports it to both `exports/fitbit_data.xlsx` and `exports/fitbit.db` (SQLite). Grafana reads from the SQLite file for health dashboards.

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
| Wallabag | Article reader |
| Python 3 + virtualenv | Fitbit export script |
| SQLite | Fitbit data storage for Grafana |
| Cron | Monthly Fitbit export trigger |

---

## Directory Structure

```
pi-services/
├── docker-compose.yml              ← Root: lifts all services
├── .gitignore
├── install-wallabag.sh             ← Legacy install script (replaced by compose)
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
├── wallabag/
│   ├── docker-compose.yml
│   ├── .env                        ← gitignored
│   └── .env.example
│
└── fitbit-exporter/
    ├── export.py
    ├── gather_keys_oauth2.py
    ├── tokens.json                 ← gitignored (credentials)
    ├── tokens.json.example
    ├── readme.md
    ├── exports/                    ← gitignored (personal health data)
    └── venv/                       ← gitignored
```

---

## Setup

### Prerequisites

- Raspberry Pi with Docker and Docker Compose installed
- Git
- Python 3 with virtualenv (for fitbit-exporter)
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
cp wallabag/.env.example wallabag/.env
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

**`wallabag/.env`**
```
PI_IP=your_pi_ip
```

### 3. Set up Fitbit exporter

```bash
cd fitbit-exporter
cp tokens.json.example tokens.json
python3 -m venv venv
source venv/bin/activate
pip install requests openpyxl
mkdir -p exports
```

Follow `fitbit-exporter/readme.md` for the full OAuth2 token setup.

### 4. Set up the cron job

```bash
crontab -e
```

Add:
```
0 6 1 * * /home/youruser/Pi-Services/fitbit-exporter/venv/bin/python /home/youruser/Pi-Services/fitbit-exporter/export.py >> /home/youruser/Pi-Services/fitbit-exporter/export.log 2>&1
```

### 5. Start all services

```bash
docker compose up -d
```

### 6. Verify

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
| View logs | `docker logs <container_name>` |
| View all status | `docker compose ps` |

---

## Access

| Service | URL |
|---|---|
| Homepage | `http://<pi_ip>:3001` |
| Grafana | `http://<pi_ip>:3000` |
| Wallabag | `http://<pi_ip>:8082` |
| Prometheus | `http://<pi_ip>:9090` |

---

## Security Notes

- `tokens.json` contains live Fitbit OAuth2 credentials — never commit it
- `.env` files contain passwords — never commit them
- All sensitive files are covered by `.gitignore`
- Use `.env.example` files as templates when setting up on a new machine
- Wallabag default credentials are `wallabag / wallabag` — change them after first login

---

## Grafana — Fitbit Dashboards

Grafana reads Fitbit data directly from `exports/fitbit.db` via the SQLite plugin. Two dashboards are provisioned automatically:

- **Fitbit Main** — activity, sleep, and heart rate overview
- **Fitbit Insights** — correlations and trends

To set up the SQLite datasource:
1. Go to **Connections → Data sources → Add data source**
2. Search for **SQLite**
3. Set path to `///var/fitbit/fitbit.db`
4. Save & test
