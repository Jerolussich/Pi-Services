# Monitoring

Stack de monitoreo del Pi basado en Prometheus y Grafana. Recolecta métricas del sistema y de Pi-hole, y visualiza también los datos de salud de Fitbit desde SQLite y las finanzas desde SQLite.

---

## Arquitectura

```
Node Exporter (sistema)  ──┐
Pi-hole Exporter         ──┼──→ Prometheus → Grafana
                           │                    ↑
fitbit.db (SQLite)  ───────────────────────────┤
finance.db (SQLite) ───────────────────────────┘
```

---

## Servicios

| Contenedor | Imagen | Puerto | Descripción |
|---|---|---|---|
| `prometheus` | `prom/prometheus` | `9090` | Recolecta y almacena métricas |
| `node-exporter` | `prom/node-exporter` | `9100` | Expone métricas del sistema (CPU, RAM, disco, red) |
| `pihole-exporter` | `amonacoos/pihole6_exporter` | `9666` | Expone métricas de Pi-hole v6 para Prometheus |
| `grafana` | `grafana/grafana-oss` | `3000` | Visualización de métricas y dashboards |

---

## Estructura

```
monitoring/
├── docker-compose.yml
├── .env                          ← gitignored
├── .env.example
├── prometheus.yml                ← Configuración de scraping
└── grafana/
    ├── dashboards/
    │   ├── fitbit/
    │   │   ├── fitbit_dashboard.json
    │   │   └── fitbit_insights_dashboard.json
    │   ├── finance/
    │   │   └── finance_dashboard.json
    │   └── pihole/
    │       └── pihole_dashboard.json
    └── provisioning/
        └── dashboards/
            └── dashboards.yaml   ← Auto-provisioning de dashboards
```

---

## Setup

### 1. Configurar el .env

```bash
cp .env.example .env
```

Editar `.env`:

```
PIHOLE_API_KEY=tu_app_password_de_pihole
FITBIT_EXPORTS_PATH=/home/youruser/pi-services/fitbit-exporter/exports
FINANCE_DATA_PATH=/home/youruser/pi-services/finance/itau-tracker/data
```

#### Cómo obtener la API Key de Pi-hole v6

1. Entrar a `http://pihole.pi/admin`
2. Settings → API
3. Copiar el **App Password**

### 2. Levantar los contenedores

Desde la raíz del repo:

```bash
docker compose up -d prometheus node-exporter pihole-exporter grafana
```

O solo este stack desde su carpeta:

```bash
cd monitoring
docker compose up -d
```

### 3. Verificar

```bash
docker compose ps
```

Todos deben mostrar `Up`. Acceder a Grafana en `http://grafana.pi`.

---

## Variables de entorno

| Variable | Descripción | Ejemplo |
|---|---|---|
| `PIHOLE_API_KEY` | App Password de Pi-hole v6 | `abc123...` |
| `FITBIT_EXPORTS_PATH` | Ruta al host donde vive `fitbit.db` | `/home/user/pi-services/fitbit-exporter/exports` |
| `FINANCE_DATA_PATH` | Ruta al host donde vive la DB de finanzas | `/home/user/pi-services/finance/itau-tracker/data` |

---

## Prometheus

### Configuración de scraping

`prometheus.yml` define los targets que Prometheus scrapea cada 15 segundos:

| Job | Target | Descripción |
|---|---|---|
| `prometheus` | `localhost:9090` | Métricas del propio Prometheus |
| `node` | `node-exporter:9100` | Métricas del sistema |
| `pihole` | `pihole-exporter:9666` | Métricas de Pi-hole |

Para agregar un nuevo target, editar `prometheus.yml` y reiniciar:

```bash
docker compose up -d --force-recreate prometheus
```

### Verificar targets

Ir a `http://prometheus.pi/targets` — todos deben estar en estado `UP`.

---

## Grafana

### Acceso

URL: `http://grafana.pi`

### Dashboards

Los dashboards se provisionan automáticamente desde `grafana/dashboards/` al iniciar el contenedor.

| Dashboard | Carpeta en Grafana | Descripción |
|---|---|---|
| Fitbit Main | Fitbit | Actividad, sueño y frecuencia cardíaca |
| Fitbit Insights | Fitbit | Correlaciones y tendencias |
| Finance | Finance | Transacciones Itaú |
| Pi-hole v6 | Pihole | Queries DNS, bloqueos, clientes |

Para el dashboard de sistema (Node Exporter), importar desde Grafana:
1. **Dashboards → Import**
2. ID: `1860` (Node Exporter Full)
3. Seleccionar el datasource Prometheus

### Datasources

| Nombre | Tipo | Descripción |
|---|---|---|
| `prometheus` | Prometheus | Métricas del sistema y Pi-hole |
| `Fitbit` | SQLite | Base de datos de Fitbit |
| `Finance SQLite` | SQLite | Base de datos de finanzas |

#### Datasource SQLite (Fitbit / Finance)

Si hay que reinstalar el plugin:

```bash
docker exec -it grafana grafana-cli plugins install frser-sqlite-datasource
docker restart grafana
```

Paths de los archivos:
- Fitbit: `///var/fitbit/fitbit.db`
- Finance: `///var/finance/finance.db`

### Reemplazar UID del datasource en los dashboards

Si el datasource tiene un UID distinto al hardcodeado en los JSON:

```bash
# Obtener los UIDs reales
curl -s http://admin:TU_PASSWORD@grafana.pi/api/datasources | python3 -m json.tool | grep -E '"uid"|"name"'

# Reemplazar en los dashboards
sed -i 's/UID_VIEJO/UID_NUEVO/g' grafana/dashboards/fitbit/fitbit_dashboard.json

# Reiniciar para que tome los cambios
docker compose up -d --force-recreate grafana
```

---

## Volúmenes

| Volumen | Tipo | Descripción |
|---|---|---|
| `monitoring_grafana-data` | Named volume | Base de datos interna de Grafana |
| `prometheus-data` | Named volume | Series de tiempo de Prometheus |
| `${FITBIT_EXPORTS_PATH}` | Bind mount (ro) | Exports de Fitbit |
| `${FINANCE_DATA_PATH}` | Bind mount (ro) | Datos de finanzas |
| `./grafana/provisioning` | Bind mount | Config de auto-provisioning |
| `./grafana/dashboards` | Bind mount | Archivos JSON de dashboards |

---

## Notas de arquitectura

### Pi-hole
Pi-hole corre directamente en el host (no en Docker) en el puerto **8181**. El puerto 80 está ocupado por Caddy. El exporter se conecta a `192.168.68.66:8181` para saltear Caddy, que bloquea el acceso por IP con un catch-all `403`.

### Red Docker
Todos los servicios usan la red externa `pi-services` definida como:
```yaml
networks:
  default:
    external: true
    name: pi-services
```

---

## Troubleshooting

| Problema | Causa | Solución |
|---|---|---|
| Target en estado `DOWN` en Prometheus | Contenedor caído o mal configurado | `docker logs <contenedor>` |
| Pi-hole exporter `403` | Usando API vieja (pre-v6) o key incorrecta | Verificar que la imagen sea `amonacoos/pihole6_exporter` y `PIHOLE_API_KEY` en `.env` |
| Pi-hole exporter sin conexión | Caddy bloqueando acceso por IP | El exporter debe apuntar a `192.168.68.66:8181`, no al puerto 80 |
| Grafana no carga datos de Fitbit | Path del SQLite incorrecto | Verificar `FITBIT_EXPORTS_PATH` en `.env` |
| Dashboard sin datos | UID del datasource incorrecto | Ver sección Grafana → reemplazar UID |
| `Login failed` en Grafana | Volumen recreado con datos vacíos | Verificar que se use el volumen `monitoring_grafana-data` |
| Dashboard provisionado no aparece | UID conflicto con dashboard importado manualmente | Cambiar el `uid` en el JSON y reiniciar Grafana |
