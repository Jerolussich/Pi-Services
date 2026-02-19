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
├── fitbit-exporter → Monthly export container (no port, writes to SQLite)
└── news            → Reserved for future use
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

### Wallabag
**Image:** `wallabag/wallabag`  
**Port:** `8082`  
Clean article reading without ads or account barriers. Data persists in a named Docker volume.

### Fitbit Exporter
**Image:** built from `fitbit-exporter/Dockerfile`  
Runs a cron job inside a container that triggers on the 1st of every month at 6am. Fetches the previous month's data from the Fitbit API and exports it to both `exports/fitbit_data.xlsx` and `exports/fitbit.db` (SQLite). `tokens.json` and `exports/` are bind-mounted from the host so credentials and data persist across container rebuilds. Grafana reads from the SQLite file for health dashboards.

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
| Python 3 + Docker | Fitbit export script (containerized) |
| SQLite | Fitbit data storage for Grafana |
| Cron | Monthly Fitbit export trigger |

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
├── wallabag/
│   ├── docker-compose.yml
│   ├── .env                        ← gitignored
│   └── .env.example
│
└── fitbit-exporter/
    ├── Dockerfile
    ├── docker-compose.yml
    ├── export.py
    ├── requirements.txt
    ├── gather_keys_oauth2.py
    ├── tokens.json                 ← gitignored (credentials), bind-mounted
    ├── tokens.json.example
    ├── readme.md
    └── exports/                    ← gitignored (personal health data), bind-mounted
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
mkdir -p exports
```

Fill in your Fitbit credentials in `tokens.json`. Follow `fitbit-exporter/readme.md` for the full OAuth2 token setup.

### 4. Start all services

```bash
docker compose up -d
```

### 5. Verify

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
