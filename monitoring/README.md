# Monitoring

Stack de monitoreo del Pi basado en Prometheus y Grafana. Recolecta métricas del sistema y de Pi-hole, y visualiza también los datos de salud de Fitbit desde SQLite.

---

## Arquitectura

```
Node Exporter (sistema)  ──┐
Pi-hole Exporter         ──┼──→ Prometheus → Grafana
                           │                    ↑
fitbit.db (SQLite)  ───────────────────────────┘
```

---

## Servicios

| Contenedor | Imagen | Puerto | Descripción |
|---|---|---|---|
| `prometheus` | `prom/prometheus` | `9090` | Recolecta y almacena métricas |
| `node-exporter` | `prom/node-exporter` | `9100` | Expone métricas del sistema (CPU, RAM, disco, red) |
| `pihole-exporter` | `ekofr/pihole-exporter` | `9617` | Expone métricas de Pi-hole para Prometheus |
| `grafana` | `grafana/grafana-oss` | `3000` | Visualización de métricas y dashboards |

---

## Estructura

```
monitoring/
├── docker-compose.yml
├── .env                          ← gitignored
├── .env.example
├── prometheus.yml                ← Configuración de scraping
├── get-docker.sh                 ← Script de instalación de Docker
└── grafana/
    ├── dashboards/
    │   ├── fitbit_dashboard.json
    │   └── fitbit_insights_dashboard.json
    └── provisioning/
        └── dashboards/
            └── fitbit.yaml       ← Auto-provisioning de dashboards
```

---

## Setup

### 1. Configurar el .env

```bash
cp .env.example .env
```

Editar `.env`:

```
PIHOLE_PASSWORD=tu_password_de_pihole
FITBIT_EXPORTS_PATH=/home/youruser/Pi-Services/fitbit-exporter/exports
```

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

Todos deben mostrar `Up`. Acceder a Grafana en `http://<pi_ip>:3000`.

---

## Variables de entorno

| Variable | Descripción | Ejemplo |
|---|---|---|
| `PIHOLE_PASSWORD` | Password del admin de Pi-hole | `tu_password` |
| `FITBIT_EXPORTS_PATH` | Ruta al host donde vive `fitbit.db` | `/home/user/Pi-Services/fitbit-exporter/exports` |

`FITBIT_EXPORTS_PATH` se monta como volumen read-only en Grafana para que pueda leer el SQLite de Fitbit.

---

## Prometheus

### Configuración de scraping

`prometheus.yml` define los targets que Prometheus scrapea cada 15 segundos:

| Job | Target | Descripción |
|---|---|---|
| `prometheus` | `localhost:9090` | Métricas del propio Prometheus |
| `node` | `node-exporter:9100` | Métricas del sistema |
| `pihole` | `pihole-exporter:9617` | Métricas de Pi-hole |

Para agregar un nuevo target, editar `prometheus.yml` y reiniciar:

```bash
docker compose up -d --force-recreate prometheus
```

### Verificar targets

Ir a `http://<pi_ip>:9090/targets` — todos deben estar en estado `UP`.

---

## Grafana

### Acceso

URL: `http://<pi_ip>:3000`  
Credenciales por defecto: `admin / admin` — cambiarlas en el primer login.

### Dashboards

Los dashboards se provisionan automáticamente desde `grafana/dashboards/` al iniciar el contenedor. Aparecen en la carpeta **Fitbit** dentro de Grafana.

| Dashboard | Descripción |
|---|---|
| Fitbit Main | Actividad, sueño y frecuencia cardíaca |
| Fitbit Insights | Correlaciones y tendencias |

Para el dashboard de sistema (Node Exporter), importar desde Grafana:
1. **Dashboards → Import**
2. ID: `1860` (Node Exporter Full)
3. Seleccionar el datasource Prometheus

### Datasource SQLite (para Fitbit)

1. Instalar el plugin:
```bash
docker exec -it grafana grafana-cli plugins install frser-sqlite-datasource
docker restart grafana
```

2. Ir a **Connections → Data sources → Add data source**
3. Buscar **SQLite**
4. En **Path**: `///var/fitbit/fitbit.db`
5. **Save & test**

### Reemplazar UID del datasource en los dashboards

Si el datasource SQLite tiene un UID distinto al que está hardcodeado en los JSON:

```bash
# Obtener el UID real
curl -s http://admin:TU_PASSWORD@localhost:3000/api/datasources | python3 -m json.tool | grep -E '"uid"|"name"'

# Reemplazar en los dashboards
sed -i 's/\${DS_FITBIT}/EL_UID_REAL/g' grafana/dashboards/fitbit_dashboard.json
sed -i 's/\${DS_FITBIT}/EL_UID_REAL/g' grafana/dashboards/fitbit_insights_dashboard.json

# Reiniciar para que tome los cambios
docker compose up -d --force-recreate grafana
```

---

## Volúmenes

| Volumen | Tipo | Descripción |
|---|---|---|
| `monitoring_grafana-data` | Named volume | Base de datos interna de Grafana (usuarios, alertas, config) |
| `prometheus-data` | Named volume | Series de tiempo almacenadas por Prometheus |
| `${FITBIT_EXPORTS_PATH}` | Bind mount (ro) | Carpeta de exports de Fitbit, montada read-only |
| `./grafana/provisioning` | Bind mount | Config de auto-provisioning de dashboards |
| `./grafana/dashboards` | Bind mount | Archivos JSON de los dashboards |

El volumen de Grafana usa `name: monitoring_grafana-data` explícitamente para que no cambie si el stack se levanta desde la raíz del repo o desde esta carpeta.

---

## Troubleshooting

| Problema | Causa | Solución |
|---|---|---|
| Target en estado `DOWN` en Prometheus | Contenedor caído o mal configurado | `docker logs <contenedor>` para ver el error |
| Grafana no carga datos de Fitbit | Path del SQLite incorrecto | Verificar `FITBIT_EXPORTS_PATH` en `.env` y que el archivo exista |
| `Login failed` en Grafana | Volumen recreado con datos vacíos | Verificar que se use el volumen `monitoring_grafana-data` |
| Dashboard sin datos | UID del datasource incorrecto | Ver sección Grafana → reemplazar UID |
| Pi-hole exporter en `DOWN` | Password incorrecto | Verificar `PIHOLE_PASSWORD` en `.env` |
