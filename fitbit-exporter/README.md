# Fitbit Exporter

Exportación automática mensual de datos de Fitbit a un Excel acumulativo y base de datos SQLite, con visualización en Grafana. Corre como contenedor Docker en Raspberry Pi.

---

## Arquitectura

```
Fitbit API
    ↓
export.py (cron dentro del contenedor — 1ro de cada mes, 6am)
    ↓              ↓
fitbit_data.xlsx   fitbit.db (SQLite)
                       ↓
                   Grafana Dashboard
                       ↓
                   Homepage (link)
```

---

## Componentes

| Componente | Descripción | Ubicación |
|---|---|---|
| `export.py` | Script principal de exportación | `fitbit-exporter/export.py` |
| `Dockerfile` | Imagen Docker con Python + cron | `fitbit-exporter/Dockerfile` |
| `requirements.txt` | Dependencias Python | `fitbit-exporter/requirements.txt` |
| `tokens.json` | Credenciales OAuth2 de Fitbit | `fitbit-exporter/tokens.json` (gitignored) |
| `fitbit_data.xlsx` | Excel acumulativo con toda la data | `fitbit-exporter/exports/` (gitignored) |
| `fitbit.db` | Base de datos SQLite para Grafana | `fitbit-exporter/exports/` (gitignored) |
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

```bash
docker exec fitbit-exporter python /app/export.py
```

Output esperado:
```
Exportando datos de 2026-01-01 a 2026-01-31...
✓ Token renovado automáticamente.
Obteniendo steps y actividad...
Obteniendo sueño...
Obteniendo frecuencia cardíaca...
Obteniendo SpO2...
Obteniendo logs de actividades...
✓ Datos guardados en SQLite.
✓ Exportado: /app/exports/fitbit_data.xlsx
```

---

## Cómo funciona el contenedor

El `Dockerfile` instala Python, las dependencias de `requirements.txt`, copia `export.py`, e instala un cron job que corre el 1ro de cada mes a las 6am. El contenedor corre `cron -f` como proceso principal.

`tokens.json` y `exports/` son bind mounts — viven en el host y son accesibles tanto desde el contenedor como desde Grafana.

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

- **Mes exportado**: siempre el mes anterior a la fecha de ejecución
- **Token**: se renueva automáticamente en cada ejecución usando el refresh token
- **Duplicados**: si el mes ya fue exportado en el xlsx y en el SQLite, lo omite sin sobreescribir
- **Rate limit**: la API de Fitbit permite 150 llamadas/hora. Si se supera, volver a correr una hora después
- **SpO2**: requiere el scope `oxygen_saturation` en el token. Si da 403, reautorizar con ese scope habilitado

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

**Ver logs del cron:**
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
