# News

Stack de lectura y filtrado automático de noticias. Combina FreshRSS para agregar feeds RSS, un filtro automático por keywords, y Wallabag para guardar y leer los artículos relevantes de forma limpia.

---

## Arquitectura

```
FreshRSS
├── agrega feeds RSS configurados
├── hace fetch full content de cada artículo
└── expone artículos via API (Google Reader API)
         ↓
news-filter (cron diario — 8am)
├── lee artículos de las últimas 24hs
├── busca keywords en título + contenido completo
├── si contenido es corto (<500 chars) → fallback a Wallabag scraper
├── chequea seen.db → ¿ya procesado?
├── match → guarda en Wallabag, registra wallabag_id en seen.db
└── no match → descarta, limpia Wallabag si se usó como scraper
         ↓
Wallabag
└── almacena artículos relevantes para leer sin ads ni clutter

news-filter-ui
└── interfaz web para editar keywords y ver logs de ejecución
```

---

## Servicios

| Contenedor | Imagen | URL | Descripción |
|---|---|---|---|
| `freshrss` | `freshrss/freshrss:latest` | `http://freshrss.pi` | Agregador de feeds RSS |
| `wallabag` | `wallabag/wallabag` | `http://wallabag.pi` | Lector de artículos |
| `news-filter` | build local | — | Filtro automático (cron) |
| `news-filter-ui` | build local | `http://news.pi` | UI para keywords y logs |

---

## Estructura

```
news/
├── freshrss/
│   ├── docker-compose.yml
│   └── .env.example
│
├── wallabag/
│   ├── docker-compose.yml
│   ├── .env                  ← gitignored
│   └── .env.example
│
└── news-filter/
    ├── docker-compose.yml    ← define both news-filter AND news-filter-ui
    ├── Dockerfile            ← cron container
    ├── filter.py
    ├── requirements.txt
    ├── .env                  ← gitignored
    ├── .env.example
    ├── config/
    │   └── keywords.txt      ← bind-mount, editar directo desde host o via UI
    ├── data/                 ← gitignored
    │   ├── seen.db
    │   ├── filter.log
    │   └── paused            ← archivo centinela para pausar el cron
    └── ui/
        ├── Dockerfile        ← Flask UI container
        ├── app.py
        ├── requirements.txt
        ├── .env              ← gitignored (UI_USERNAME, UI_PASSWORD, SECRET_KEY)
        ├── .env.example
        └── templates/
            └── index.html
```

---

## Setup

### 1. Configurar variables de entorno

```bash
cp news/wallabag/.env.example news/wallabag/.env
cp news/news-filter/.env.example news/news-filter/.env
cp news/news-filter/ui/.env.example news/news-filter/ui/.env
```

**`news/wallabag/.env`**
```
PI_IP=your_pi_ip
```

**`news/news-filter/.env`**
```
FRESHRSS_URL=http://freshrss
FRESHRSS_USERNAME=admin
FRESHRSS_API_PASSWORD=your_freshrss_api_password
WALLABAG_URL=http://wallabag
WALLABAG_CLIENT_ID=your_client_id
WALLABAG_CLIENT_SECRET=your_client_secret
WALLABAG_USERNAME=wallabag
WALLABAG_PASSWORD=your_wallabag_password
EXTRA_KEYWORDS=
MIN_CONTENT_LENGTH=500
SEEN_RETENTION_DAYS=30
LOG_RETENTION_DAYS=90
```

**`news/news-filter/ui/.env`**
```
UI_USERNAME=admin
UI_PASSWORD=your_ui_password
SECRET_KEY=your_secret_key
```

Generar `SECRET_KEY` con:
```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```

### 2. Crear carpetas necesarias

```bash
mkdir -p news/news-filter/config
mkdir -p news/news-filter/data
```

### 3. Crear keywords iniciales

```bash
cat > news/news-filter/config/keywords.txt << 'EOF'
artificial intelligence
machine learning
openai
anthropic
EOF
```

### 4. Levantar los servicios

```bash
docker compose up -d freshrss wallabag news-filter news-filter-ui
```

### 5. Configurar FreshRSS (primera vez)

1. Abrir `http://freshrss.pi`
2. Completar el wizard de instalación con usuario y password admin
3. Ir a **Settings → Authentication** → habilitar **Allow API access**
4. Ir a **Settings → Profile** → setear **API password**
5. Ir a **Settings → Archiving** → setear **Days to keep articles** a `30`

### 6. Agregar feeds RSS

1. Click **+** en el sidebar → pegar URL del feed
2. Una vez agregado, ir a **Feed settings → Advanced**
3. En **Article CSS selector on original website** poner `article` para habilitar fetch full content

Feeds recomendados:
```
https://rss.nytimes.com/services/xml/rss/nyt/Technology.xml
https://feeds.arstechnica.com/arstechnica/technology-lab
https://www.theverge.com/rss/index.xml
https://techcrunch.com/feed/
```

### 7. Configurar Wallabag (primera vez)

1. Abrir `http://wallabag.pi`
2. Login con `wallabag / wallabag`
3. Cambiar el password en **Settings → Change password**
4. Crear API client en **API clients management → Create a client**
5. Guardar el `client_id` y `client_secret` en `news/news-filter/.env`

### 8. Probar el filtro manualmente

```bash
docker exec news-filter python /app/filter.py
```

O desde la UI en `http://news.pi` → **Run filter now**.

---

## news-filter — Detalles técnicos

### Flujo de procesamiento

```
Para cada artículo de las últimas 24hs en FreshRSS:

1. ¿URL ya está en seen.db? → skip
2. Obtener contenido desde FreshRSS API
3. ¿Contenido < MIN_CONTENT_LENGTH chars?
   └── Sí → guardar en Wallabag temporalmente (usa su scraper)
4. Buscar keywords en título + contenido
5. ¿Match?
   ├── Sí → guardar en Wallabag (si no está ya), registrar wallabag_id en seen.db
   └── No → descartar, borrar de Wallabag si se guardó temporalmente, registrar en seen.db
```

### Deduplicación — seen.db

```sql
CREATE TABLE seen (
    url         TEXT PRIMARY KEY,
    saved_at    TEXT,
    wallabag_id INTEGER   -- NULL si no fue guardado en Wallabag
)
```

- Cada URL procesada se registra independientemente del resultado
- `wallabag_id` se guarda para poder borrar el artículo de Wallabag al limpiar
- Registros de más de `SEEN_RETENTION_DAYS` días se limpian automáticamente en cada run

### Variables de entorno

| Variable | Descripción | Default |
|---|---|---|
| `FRESHRSS_URL` | URL de FreshRSS | — |
| `FRESHRSS_USERNAME` | Usuario de FreshRSS | — |
| `FRESHRSS_API_PASSWORD` | API password de FreshRSS | — |
| `WALLABAG_URL` | URL de Wallabag | — |
| `WALLABAG_CLIENT_ID` | OAuth2 client ID | — |
| `WALLABAG_CLIENT_SECRET` | OAuth2 client secret | — |
| `WALLABAG_USERNAME` | Usuario de Wallabag | — |
| `WALLABAG_PASSWORD` | Password de Wallabag | — |
| `EXTRA_KEYWORDS` | Keywords adicionales separados por coma | `` |
| `MIN_CONTENT_LENGTH` | Mínimo de chars para no usar fallback | `500` |
| `SEEN_RETENTION_DAYS` | Días antes de limpiar entradas viejas de seen.db | `30` |
| `LOG_RETENTION_DAYS` | Días antes de rotar líneas viejas del log | `90` |

### Cron

Corre automáticamente todos los días a las 8am:
```
0 8 * * * python /app/filter.py >> /app/data/filter.log 2>&1
```

Para correr manualmente:
```bash
docker exec news-filter python /app/filter.py
```

---

## news-filter-ui — Detalles técnicos

Aplicación Flask ubicada en `ui/`. Comparte los mismos bind-mounts que el contenedor del cron.

| Volumen | Descripción |
|---|---|
| `./config` | Lee y escribe `keywords.txt` |
| `./data` | Lee `filter.log`, lee/escribe `seen.db`, crea/borra `paused` |
| `./filter.py` | Ejecuta el script vía **Run filter now** |
| `.env` (news-filter) | Env vars para ejecutar `filter.py` y reset |
| `ui/.env` | `UI_USERNAME`, `UI_PASSWORD`, `SECRET_KEY` |

### Autenticación y seguridad

La UI está protegida con HTTP Basic Auth. Las credenciales se configuran en `ui/.env`.

Todos los endpoints POST tienen protección CSRF (`flask-wtf`) y rate limiting (`flask-limiter`). Requests sin token CSRF válido devuelven `400`. IPs que superen el límite reciben `429`.

| Endpoint | Límite |
|---|---|
| `/save` | 10/min |
| `/run` | 5/min |
| `/toggle-pause` | 10/min |
| `/reset` | 3/min |
| `/log` | exempt (GET, usado por el poller) |

### Auto-refresh del log

Al hacer click en **Run filter now**, la página redirige con `?running=1`. JavaScript hace polling al endpoint `/log` cada 2 segundos durante 30 segundos. Un indicador **● live** aparece mientras está activo.

Endpoints:
- `GET /` — muestra keywords actuales, últimas 100 líneas del log, y estado de pausa
- `GET /log` — devuelve JSON con el contenido actual del log (usado por el poller)
- `POST /save` — guarda keywords editadas
- `POST /run` — ejecuta `filter.py` en background, redirige con `?running=1`
- `POST /toggle-pause` — crea o borra `/app/data/paused`
- `POST /reset` — borra artículos de Wallabag trackeados, limpia seen.db, borra log, marca todos los artículos de FreshRSS como leídos

### Pause/Resume

Funciona mediante un archivo centinela `/app/data/paused`. Cuando existe, `filter.py` sale sin procesar nada. El cron sigue disparándose pero no hace nada.

### Reset everything

El botón de reset hace en orden:
1. Obtiene token OAuth2 de Wallabag
2. Borra todos los artículos con `wallabag_id` registrado en `seen.db`
3. Marca todos los artículos de FreshRSS como leídos via API
4. Limpia todas las filas de `seen.db`
5. Vacía `filter.log`

---

## Retención de datos

| Dato | Retención | Configuración |
|---|---|---|
| Artículos en FreshRSS | 30 días | Settings → Archiving en FreshRSS UI |
| Entradas en seen.db | 30 días | `SEEN_RETENTION_DAYS` en `.env` |
| Artículos en Wallabag | 30 días (automático) | Borrado por `cleanup_old()` al limpiar seen.db |
| filter.log | 90 días (rotación automática) | `LOG_RETENTION_DAYS` en `.env` |

---

## Volúmenes

| Volumen | Tipo | Descripción |
|---|---|---|
| `freshrss-data` | Named | Artículos y config de FreshRSS |
| `freshrss-extensions` | Named | Extensiones de FreshRSS |
| `wallabag-data` | Named | Artículos guardados y config de Wallabag |
| `./news-filter/config` | Bind mount | `keywords.txt` compartido con la UI |
| `./news-filter/data` | Bind mount | `seen.db` y `filter.log` compartidos con la UI |

---

## Troubleshooting

| Problema | Causa | Solución |
|---|---|---|
| `FreshRSS auth failed` | API password incorrecto o API no habilitada | Verificar **Settings → Authentication** y **Profile → API password** |
| `0 articles fetched` | No hay artículos en las últimas 24hs | Hacer **Refresh all feeds** en FreshRSS manualmente |
| Artículos guardados sin contenido | Feed truncado y Wallabag no pudo scrapear | Habilitar **fetch full content** con selector `article` en el feed |
| `Last run log` vacío en UI | filter.py no está escribiendo al log file | Verificar que `./data` está bind-mounted correctamente |
| Wallabag lleno de artículos viejos | `SEEN_RETENTION_DAYS` muy alto | Correr filter manualmente para disparar `cleanup_old()` |
| `KeyError: FRESHRSS_URL` | `.env` no montado en news-filter-ui | Verificar `env_file` en `docker-compose.yml` |
| `400 Bad Request` en Wallabag token | Client ID/secret o password incorrecto | Recrear el API client en Wallabag y actualizar `.env` |
| Filter corre pero no hace nada | Está pausado | Verificar si existe `/app/data/paused`, usar botón **Resume** |
| Wallabag recreado desde cero | Volumen borrado o recreado | Recrear API client y actualizar `WALLABAG_CLIENT_ID`, `WALLABAG_CLIENT_SECRET` |
| UI devuelve 400 al enviar formulario | Token CSRF faltante | No enviar formularios via curl sin cookie de sesión válida |
| UI devuelve 429 | Rate limit alcanzado | Esperar 1 minuto y reintentar |
