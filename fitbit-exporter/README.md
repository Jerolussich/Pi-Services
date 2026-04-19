# Fitbit Exporter

Exportación mensual de datos de Fitbit a un Excel acumulativo y base de datos SQLite, con visualización en Grafana y una UI web (`fitbit.pi`) para disparar ingestas manuales por mes y ver qué meses ya están cargados.

---

## Arquitectura

```
Fitbit API
    ↓
export.py
 ├─ invocado por Ofelia el 1ro de cada mes 6am → --source scheduled
 └─ invocado por la UI al clickear "Ingestar" → --source manual
    ↓              ↓              ↓
fitbit_data.xlsx   fitbit.db      ingest_runs (tabla de tracking)
                       ↓              ↑
                   Grafana        fitbit-exporter-ui (Flask en :8086)
                                      ↓
                                   fitbit.pi (via Caddy)
```

Dos contenedores comparten el mismo volumen `exports/`:
- `fitbit-exporter`: corre `sleep infinity`, ejecuta `export.py` cuando Ofelia dispara.
- `fitbit-exporter-ui`: Flask + gunicorn en `:8086`. Lee `fitbit.db` para la grilla; spawnea `python /app/export.py --year Y --month M --source manual` vía `subprocess.Popen` al clickear "Ingestar".

---

## Componentes

| Componente | Descripción | Ubicación |
|---|---|---|
| `export.py` | Script principal — acepta `--year/--month/--source` | `fitbit-exporter/export.py` |
| `Dockerfile` | Imagen del exporter (`sleep infinity`) | `fitbit-exporter/Dockerfile` |
| `requirements.txt` | Dependencias Python del exporter | `fitbit-exporter/requirements.txt` |
| `ui/app.py` | Flask UI — rutas `/`, `/months`, `/ingest`, `/log` | `fitbit-exporter/ui/app.py` |
| `ui/Dockerfile` | Imagen de la UI (gunicorn en `:8086`) | `fitbit-exporter/ui/Dockerfile` |
| `ui/templates/index.html` | Date picker + grilla 18 meses + log live | `fitbit-exporter/ui/templates/index.html` |
| `ui/.env` | `UI_USERNAME`, `UI_PASSWORD`, `SECRET_KEY` | `fitbit-exporter/ui/.env` (gitignored) |
| `tokens.json` | Credenciales OAuth2 de Fitbit | `fitbit-exporter/tokens.json` (gitignored) |
| `fitbit_data.xlsx` | Excel acumulativo | `fitbit-exporter/exports/` (gitignored) |
| `fitbit.db` | SQLite: `actividad`, `sueno`, `heart_rate`, `ejercicios`, `ingest_runs` | `fitbit-exporter/exports/` (gitignored) |
| `data/fitbit-ui.log` | Log apendado por la UI al disparar ingestas | `fitbit-exporter/data/` (gitignored) |
| `fitbit_dashboard.json` | Dashboard de Grafana | `monitoring/grafana/dashboards/` |

---

## Prerrequisitos

- Raspberry Pi con Docker y Docker Compose instalados
- Cuenta de Fitbit
- App registrada en [dev.fitbit.com](https://dev.fitbit.com)

---

## Instalación

### 1. Registrar app en Fitbit

1. Ir a [dev.fitbit.com](https://dev.fitbit.com) → Register an App
2. Configurar:
   - **OAuth 2.0 Application Type**: Personal
   - **Redirect URL**: `http://127.0.0.1:8080/`
   - **Default Access Type**: Read Only
3. Guardar el **Client ID** y **Client Secret**

### 2. Obtener tokens OAuth2 (se hace UNA sola vez desde Windows)

En PowerShell en tu PC:

```powershell
pip install fitbit cherrypy
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/orcasgit/python-fitbit/master/gather_keys_oauth2.py" -OutFile "gather_keys_oauth2.py"
python gather_keys_oauth2.py TU_CLIENT_ID TU_CLIENT_SECRET
```

Se abre el browser, autorizás, y la consola imprime el `access_token` y `refresh_token`.

### 3. Crear tokens.json

```bash
cp fitbit-exporter/tokens.json.example fitbit-exporter/tokens.json
```

Editar `tokens.json` con tus credenciales:

```json
{
  "client_id": "TU_CLIENT_ID",
  "client_secret": "TU_CLIENT_SECRET",
  "access_token": "EL_ACCESS_TOKEN",
  "refresh_token": "EL_REFRESH_TOKEN"
}
```

### 4. Crear carpeta de exports

```bash
mkdir -p fitbit-exporter/exports
```

### 5. Levantar el contenedor

Desde la raíz del repo:

```bash
docker compose up -d fitbit-exporter
```

O solo este servicio desde su carpeta:

```bash
cd fitbit-exporter
docker compose up -d
```

### 6. Verificar que está corriendo

```bash
docker logs fitbit-exporter
```

### 7. Probar la exportación manualmente

Sin args corre el mes anterior:

```bash
docker exec fitbit-exporter python /app/export.py --source manual
```

Con `--year/--month` corre un mes puntual:

```bash
docker exec fitbit-exporter python /app/export.py --year 2026 --month 3 --source manual
```

Output esperado:
```
Exportando datos de 2026-03-01 a 2026-03-31 (source=manual)...
✓ Token renovado automáticamente.
Obteniendo steps y actividad...
Obteniendo sueño...
Obteniendo frecuencia cardíaca...
Obteniendo SpO2...
Obteniendo logs de actividades...
✓ Datos guardados en SQLite.
✓ Exportado: /app/exports/fitbit_data.xlsx
```

### 8. Configurar la UI

```bash
cp fitbit-exporter/ui/.env.example fitbit-exporter/ui/.env
```

Editá `UI_USERNAME`, `UI_PASSWORD` y generá un `SECRET_KEY` random:

```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```

La UI queda expuesta en `http://fitbit.pi` (requiere entry DNS en Pi-hole → `fitbit.pi` → tu IP del Pi).

---

## Cómo funciona

El `fitbit-exporter/Dockerfile` instala Python y deps, y corre `sleep infinity` como proceso principal — no tiene cron. El schedule lo maneja **Ofelia** vía `docker exec`, disparando `python /app/export.py --source scheduled` el 1ro de cada mes a las 6am (label en `docker-compose.yml`).

El `fitbit-exporter-ui/Dockerfile` levanta gunicorn en `:8086`. La UI comparte los bind mounts con el exporter (`tokens.json`, `exports/`, `export.py` en readonly, `data/`) y dispara runs manuales vía `subprocess.Popen` sobre el mismo script. No hay IPC ni queue — la tabla `ingest_runs` es el único punto de coordinación.

`tokens.json`, `exports/` y `data/` son bind mounts — viven en el host y se comparten entre contenedores.

```
Host (tu Pi)                  Contenedor
────────────────              ──────────────────
tokens.json      bind mount → /app/tokens.json
exports/         bind mount → /app/exports/
                                   ↑
                               Grafana también lee exports/
                               via ${FITBIT_EXPORTS_PATH}
```

---

## Reconstruir la imagen

Si modificás `export.py` o `requirements.txt`:

```bash
docker compose up -d --build fitbit-exporter
```

---

## Grafana

### Instalar plugin SQLite

```bash
docker exec -it grafana grafana-cli plugins install frser-sqlite-datasource
docker restart grafana
```

### Configurar datasource

1. Ir a **Connections → Data sources → Add data source**
2. Buscar **SQLite**
3. En **Path**: `///var/fitbit/fitbit.db`
4. **Save & test**

### Configurar provisioning del dashboard

El dashboard se provisiona automáticamente desde `monitoring/grafana/dashboards/`. Si necesitás reemplazar el UID del datasource:

```bash
# Obtener el UID real del datasource
curl -s http://admin:TU_PASSWORD@localhost:3000/api/datasources | python3 -m json.tool | grep -E '"uid"|"name"'

# Reemplazar en el JSON
sed -i 's/\${DS_FITBIT}/EL_UID_REAL/g' monitoring/grafana/dashboards/fitbit_dashboard.json
```

Reiniciar Grafana para que tome los cambios:

```bash
docker compose up -d --force-recreate grafana
```

---

## Dashboard — Paneles incluidos

### 📊 Actividad Diaria
- Promedio de pasos, calorías, distancia y minutos activos
- Gráfico de pasos por día
- Gráfico de calorías por día

### 😴 Sueño
- Promedio de horas dormidas, eficiencia, REM y Deep
- Fases del sueño apiladas por día (Deep, Light, REM, Despierto)
- Donut de distribución promedio de fases

### ❤️ Frecuencia Cardíaca
- Resting HR promedio y mínimo
- Total de minutos en zona Cardio
- Resting HR por día
- Minutos por zona cardíaca apilados

### 🏋️ Ejercicios
- Total de entrenamientos, duración promedio, calorías totales, HR promedio
- Pie chart de actividades más frecuentes
- Duración promedio por tipo de actividad
- Tabla historial filtrable (últimas 50 sesiones)

---

## Datos exportados

| Sheet / Tabla | Campos |
|---|---|
| Actividad | Fecha, Pasos, Calorías, Distancia (km), Minutos activos |
| Sueño | Fecha, Total (min), En cama (min), Eficiencia (%), Deep, Light, REM, Despierto |
| Heart Rate | Fecha, Resting HR (bpm), Out of Range, Fat Burn, Cardio, Peak (min) |
| SpO2 | Fecha, Promedio (%), Mínimo (%), Máximo (%) |
| Ejercicios | Fecha, Hora inicio, Actividad, Duración (min), Calorías, Distancia, Pasos, HR avg |

---

## Comportamiento del script

- **Mes por defecto**: mes anterior a la fecha de ejecución. Override con `--year YYYY --month MM` (ambos obligatorios juntos).
- **`--source`**: `scheduled` (default, usado por Ofelia) o `manual` (usado por la UI). Se graba en la tabla `ingest_runs` para poder distinguir origen de runs.
- **Token**: se renueva automáticamente en cada ejecución usando el refresh token.
- **Duplicados**: el xlsx chequea `month_already_exported()` y saltea sheets ya cargadas; el SQLite usa `INSERT OR REPLACE`, así que correr el mismo mes dos veces sobreescribe sin duplicar filas.
- **Rate limit**: la API de Fitbit permite 150 llamadas/hora. Si se supera, volver a correr una hora después.
- **SpO2**: requiere el scope `oxygen_saturation` en el token. Si da 403, reautorizar con ese scope habilitado.
- **Tracking**: al empezar se inserta una fila en `ingest_runs` con `status='running'`; al terminar se hace UPDATE a `success` o `error` (guardando el traceback). La UI consulta esta tabla para mostrar el último run por mes.

### Tabla `ingest_runs`

```sql
CREATE TABLE ingest_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    year INTEGER NOT NULL,
    month INTEGER NOT NULL,
    started_at TEXT NOT NULL,    -- ISO UTC
    finished_at TEXT,
    status TEXT NOT NULL,         -- 'running' | 'success' | 'error'
    error TEXT,                   -- traceback truncado (últimos 2000 chars) si status='error'
    source TEXT NOT NULL          -- 'manual' | 'scheduled'
);
CREATE INDEX idx_ingest_runs_ym ON ingest_runs(year, month, started_at DESC);
```

---

## UI — Ingesta manual (`fitbit.pi`)

Flask app que expone 4 endpoints, todos detrás de HTTP Basic Auth (`UI_USERNAME`/`UI_PASSWORD`):

| Ruta | Método | Descripción |
|---|---|---|
| `/` | GET | Render de `index.html` — date picker + grilla de 18 meses + log |
| `/months` | GET | JSON: `{ months: [{year, month, state, counts, last_run}], running }` — usado por el polling client-side |
| `/ingest` | POST | Valida `ym=YYYY-MM`, chequea que no haya otro run en curso para ese mes, y spawnea `python /app/export.py --year Y --month M --source manual`. Rate-limited a 5/min + CSRF. |
| `/log` | GET | Tail de `/app/data/fitbit-ui.log` (últimas 200 líneas) como JSON — polleado cada 2.5s mientras hay un run en curso. |

**Semáforo de la grilla** (lógica en `ui/app.py:collect_status`):
- 🟢 `full`: las 4 tablas (`actividad`, `sueno`, `heart_rate`, `ejercicios`) tienen al menos una fila para ese mes.
- 🟠 `partial`: algunas tablas tienen datos, otras no.
- ⚪ `empty`: ninguna tabla tiene datos.

La vista es **data-driven**: consulta `SELECT strftime('%Y-%m', fecha), COUNT(*) FROM <tabla> GROUP BY ...` en vivo. Esto hace que funcione retroactivamente: cualquier mes ya cargado (manual o scheduled, histórico o nuevo) se marca como completo sin depender del log de runs. El último run (timestamp + source + status) se lee de `ingest_runs` y se muestra como metadata debajo del label del mes.

El polling client-side detecta cuando `/months` devuelve `running: false` y recarga la página (para refrescar el semáforo de la celda recién ingestada).

### Coordinación entre scheduled y manual

Ambas rutas (Ofelia y UI) escriben a la misma `fitbit.db` y a la misma `ingest_runs`. Si se dispara un run manual al mismo tiempo que Ofelia, SQLite serializa las escrituras — en la práctica la ventana es minúscula porque Ofelia corre a las 6am el 1ro y los runs manuales son esporádicos. La UI chequea `is_running_for(year, month)` antes de spawnear para evitar duplicar el mismo mes en paralelo.

---

## Importar data histórica desde Excel al SQLite

```bash
# Subir el xlsx al Pi (desde Windows)
scp C:\Users\jerol\Desktop\fitbit_data.xlsx PI_USER@PI_IP:~/Pi-Services/fitbit-exporter/exports/fitbit_data.xlsx

# Importar al SQLite desde el contenedor
docker exec fitbit-exporter python3 << 'EOF'
import openpyxl, sqlite3

conn = sqlite3.connect("exports/fitbit.db")
c = conn.cursor()
wb = openpyxl.load_workbook("exports/fitbit_data.xlsx")

ws = wb["Actividad"]
for row in ws.iter_rows(min_row=2, values_only=True):
    if row[0]: c.execute("INSERT OR REPLACE INTO actividad VALUES (?,?,?,?,?)", row[:5])

ws = wb["Sueño"]
for row in ws.iter_rows(min_row=2, values_only=True):
    if row[0]: c.execute("INSERT OR REPLACE INTO sueno VALUES (?,?,?,?,?,?,?,?)", row[:8])

ws = wb["Heart Rate"]
for row in ws.iter_rows(min_row=2, values_only=True):
    if row[0]: c.execute("INSERT OR REPLACE INTO heart_rate VALUES (?,?,?,?,?,?)", row[:6])

ws = wb["Ejercicios"]
for row in ws.iter_rows(min_row=2, values_only=True):
    if row[0]: c.execute("INSERT OR REPLACE INTO ejercicios VALUES (?,?,?,?,?,?,?,?)", row[:8])

conn.commit()
conn.close()
print("✓ Importación completa")
EOF
```

---

## Acceso a los archivos

**Bajar xlsx a Windows:**
```powershell
scp PI_USER@PI_IP:~/Pi-Services/fitbit-exporter/exports/fitbit_data.xlsx C:\Users\jerol\Desktop\fitbit_data.xlsx
```

**Ver logs de ejecución:**
```bash
docker logs fitbit-exporter
# o
cat fitbit-exporter/exports/export.log
```

**Ver datos en SQLite:**
```bash
sqlite3 fitbit-exporter/exports/fitbit.db "SELECT * FROM actividad ORDER BY fecha DESC LIMIT 10;"
```

---

## Troubleshooting

| Problema | Causa | Solución |
|---|---|---|
| `401 Unauthorized` | Token expirado | Correr `docker exec fitbit-exporter python /app/export.py` manualmente |
| `403` en SpO2 | Falta scope `oxygen_saturation` | Reautorizar con ese scope habilitado en dev.fitbit.com |
| `429 Rate limit` | Demasiadas llamadas a la API | Esperar 1 hora y volver a correr |
| Dashboard sin datos | UID del datasource incorrecto | Ver sección Grafana → reemplazar UID |
| `no file exists at the file path` | Permisos o path incorrecto | `chmod 644 exports/fitbit.db` y verificar path con `///var/fitbit/fitbit.db` |
| Contenedor no arranca | `tokens.json` no existe | `cp tokens.json.example tokens.json` y completar credenciales |
| UI pide auth con credenciales viejas | `env_file` solo se lee al crear el contenedor | Después de tocar `ui/.env`, hacer `docker compose up -d --force-recreate fitbit-exporter-ui` (un `restart` no alcanza) |
| `fitbit.pi` no resuelve | Falta el DNS record en Pi-hole | Agregar `fitbit.pi` → IP del Pi en Pi-hole → Local DNS → DNS Records |
| UI muestra celda gris aunque el mes tiene datos | Ofelia registró el job con el comando viejo (sin `--source`) | Recrear el exporter y reiniciar ofelia: `docker compose up -d --force-recreate fitbit-exporter && docker restart ofelia` |
| Cambios a `export.py` no se aplican | Tanto el exporter como la UI montan `./export.py:/app/export.py:ro` | Un edit del archivo en el host se refleja instantáneamente en ambos — no hace falta rebuild a menos que toques `requirements.txt` |
