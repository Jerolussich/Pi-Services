# Fitbit Pi Exporter

Exportación automática mensual de datos de Fitbit a un Excel acumulativo y visualización en Grafana, corriendo en Raspberry Pi.

---

## Arquitectura general

```
Fitbit API
    ↓
export.py (cron mensual)
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
| `export.py` | Script principal de exportación | `~/fitbit-exporter/export.py` |
| `tokens.json` | Credenciales OAuth2 de Fitbit | `~/fitbit-exporter/tokens.json` |
| `fitbit_data.xlsx` | Excel acumulativo con toda la data | `~/fitbit-exporter/exports/` |
| `fitbit.db` | Base de datos SQLite para Grafana | `~/fitbit-exporter/exports/` |
| `fitbit_dashboard.json` | Dashboard de Grafana | `~/monitoring/grafana/dashboards/` |
| Cron job | Dispara la exportación el 1ro de cada mes | `crontab -l` |

---

## Prerrequisitos

- Raspberry Pi con Docker y Docker Compose
- Grafana corriendo en Docker (puerto 3000)
- Python 3 con virtualenv
- Cuenta de Fitbit
- App registrada en [dev.fitbit.com](https://dev.fitbit.com)

---

## Instalación

### 1. Crear estructura de directorios

```bash
mkdir -p ~/fitbit-exporter/exports
cd ~/fitbit-exporter
```

### 2. Crear entorno virtual e instalar dependencias

```bash
python3 -m venv venv
source venv/bin/activate
pip install requests openpyxl
```

### 3. Registrar app en Fitbit

1. Ir a [dev.fitbit.com](https://dev.fitbit.com) → Register an App
2. Configurar:
   - **OAuth 2.0 Application Type**: Personal
   - **Redirect URL**: `http://127.0.0.1:8080/`
   - **Default Access Type**: Read Only
3. Guardar el **Client ID** y **Client Secret**

### 4. Obtener tokens OAuth2 (se hace UNA sola vez desde Windows)

En PowerShell en tu PC:

```powershell
pip install fitbit cherrypy
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/orcasgit/python-fitbit/master/gather_keys_oauth2.py" -OutFile "gather_keys_oauth2.py"
python gather_keys_oauth2.py TU_CLIENT_ID TU_CLIENT_SECRET
```

Se abre el browser, autorizás, y la consola imprime el `access_token` y `refresh_token`.

### 5. Crear tokens.json en el Pi

```bash
nano ~/fitbit-exporter/tokens.json
```

```json
{
  "client_id": "TU_CLIENT_ID",
  "client_secret": "TU_CLIENT_SECRET",
  "access_token": "EL_ACCESS_TOKEN",
  "refresh_token": "EL_REFRESH_TOKEN"
}
```

### 6. Copiar el script export.py

```bash
nano ~/fitbit-exporter/export.py
```

Ver contenido completo del script en la sección [Script de exportación](#script-de-exportación).

### 7. Probar manualmente

```bash
cd ~/fitbit-exporter
source venv/bin/activate
python export.py
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
✓ Exportado: /home/jlussich/fitbit-exporter/exports/fitbit_data.xlsx
```

### 8. Configurar cron mensual

```bash
crontab -e
```

Agregar al final:
```
0 6 1 * * /home/jlussich/fitbit-exporter/venv/bin/python /home/jlussich/fitbit-exporter/export.py >> /home/jlussich/fitbit-exporter/export.log 2>&1
```

Esto corre el 1ro de cada mes a las 6am y exporta el mes anterior.

---

## Grafana

### Instalar plugin SQLite

```bash
docker exec -it grafana grafana-cli plugins install frser-sqlite-datasource
docker restart grafana
```

### Montar carpeta de exports en el contenedor

En `~/monitoring/docker-compose.yml`, agregar bajo `grafana > volumes`:

```yaml
grafana:
  image: grafana/grafana-oss
  container_name: grafana
  ports:
    - 3000:3000
  volumes:
    - grafana-data:/var/lib/grafana
    - /home/jlussich/fitbit-exporter/exports:/var/fitbit:ro
    - /home/jlussich/monitoring/grafana/provisioning:/etc/grafana/provisioning
    - /home/jlussich/monitoring/grafana/dashboards:/var/lib/grafana/dashboards
  restart: unless-stopped
```

Reiniciar:

```bash
cd ~/monitoring
docker compose down grafana && docker compose up -d grafana
```

### Configurar datasource

1. Ir a **Connections → Data sources → Add data source**
2. Buscar **SQLite**
3. En **Path**: `///var/fitbit/fitbit.db`
4. **Save & test**

### Configurar provisioning del dashboard

```bash
mkdir -p ~/monitoring/grafana/provisioning/dashboards
mkdir -p ~/monitoring/grafana/dashboards
```

Crear `~/monitoring/grafana/provisioning/dashboards/fitbit.yaml`:

```yaml
apiVersion: 1
providers:
  - name: fitbit
    folder: Fitbit
    type: file
    options:
      path: /var/lib/grafana/dashboards
```

Copiar el `fitbit_dashboard.json` a `~/monitoring/grafana/dashboards/` y reemplazar el UID del datasource:

```bash
# Obtener el UID real del datasource
curl -s http://admin:TU_PASSWORD@localhost:3000/api/datasources | python3 -m json.tool | grep -E '"uid"|"name"'

# Reemplazar en el JSON
sed -i 's/\${DS_FITBIT}/EL_UID_REAL/g' ~/monitoring/grafana/dashboards/fitbit_dashboard.json
```

Reiniciar Grafana y el dashboard aparece automáticamente en la carpeta **Fitbit**.

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
- Minutos por zona cardíaca apilados (Out of Range, Fat Burn, Cardio, Peak)

### 🏋️ Ejercicios
- Total de entrenamientos, duración promedio, calorías totales, HR promedio
- Pie chart de actividades más frecuentes
- Duración promedio por tipo de actividad
- Tabla historial filtrable (últimas 50 sesiones)

---

## Datos exportados

El script exporta los siguientes datos por mes:

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

Si tenés data en `fitbit_data.xlsx` y querés sincronizarla a la base de datos SQLite:

```bash
# Subir el xlsx al Pi (desde Windows)
scp C:\Users\jerol\Desktop\fitbit_data.xlsx jlussich@192.168.68.66:/home/jlussich/fitbit-exporter/exports/fitbit_data.xlsx

# Importar al SQLite
cd ~/fitbit-exporter
source venv/bin/activate
python3 << 'EOF'
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
scp jlussich@192.168.68.66:~/fitbit-exporter/exports/fitbit_data.xlsx C:\Users\jerol\Desktop\fitbit_data.xlsx
```

**Ver logs del cron:**
```bash
cat ~/fitbit-exporter/export.log
```

**Ver datos en SQLite:**
```bash
sqlite3 ~/fitbit-exporter/exports/fitbit.db "SELECT * FROM actividad ORDER BY fecha DESC LIMIT 10;"
```

---

## Homepage

El dashboard está linkado en Homepage con:

```yaml
- Fitbit Dashboard:
    icon: mdi-heart-pulse
    href: http://192.168.68.66:3000/d/fitbit-main-dashboard
    description: Actividad, sueño y ejercicios
```

---

## Troubleshooting

| Problema | Causa | Solución |
|---|---|---|
| `401 Unauthorized` | Token expirado | Correr `export.py` manualmente, renueva automáticamente |
| `403` en SpO2 | Falta scope `oxygen_saturation` | Reautorizar con ese scope habilitado en dev.fitbit.com |
| `429 Rate limit` | Demasiadas llamadas a la API | Esperar 1 hora y volver a correr |
| Dashboard sin datos | UID del datasource incorrecto | Ver sección Grafana → reemplazar UID |
| `no file exists at the file path` | Permisos o path incorrecto | `chmod 644 exports/fitbit.db` y verificar path con `///var/fitbit/fitbit.db` |
