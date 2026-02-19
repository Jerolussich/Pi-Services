# Wallabag

Lector de artículos self-hosted. Guarda cualquier artículo de la web y lo presenta limpio, sin publicidad, sin tracking, sin necesidad de cuenta en el sitio original.

---

## Estructura

```
wallabag/
├── docker-compose.yml
├── .env                  ← gitignored
└── .env.example
```

Los datos persisten en el named volume `wallabag-data` — no se pierden al reiniciar o recrear el contenedor.

---

## Setup

### 1. Configurar el .env

```bash
cp .env.example .env
```

Editar `.env`:

```
PI_IP=your_pi_ip
```

### 2. Levantar el contenedor

Desde la raíz del repo:

```bash
docker compose up -d wallabag
```

O solo este servicio desde su carpeta:

```bash
cd wallabag
docker compose up -d
```

### 3. Primer login

Acceder en `http://<pi_ip>:8082`

Credenciales por defecto:
- **Usuario:** `wallabag`
- **Password:** `wallabag`

⚠️ Cambiar el password inmediatamente después del primer login en **Settings → Change password**.

---

## Variables de entorno

| Variable | Descripción | Ejemplo |
|---|---|---|
| `PI_IP` | IP del Pi en la red local | `192.168.68.66` |

`PI_IP` se usa para setear `SYMFONY__ENV__DOMAIN_NAME`, que Wallabag necesita para generar links internos correctamente.

---

## Volúmenes

| Volumen | Tipo | Descripción |
|---|---|---|
| `wallabag-data` | Named volume | Artículos guardados, usuarios y configuración |

Al ser un named volume, Docker gestiona su ubicación en `/var/lib/docker/volumes/wallabag-data/`. No hace falta acceder a los archivos directamente desde el host.

---

## Uso básico

- **Guardar un artículo**: pegar la URL en el campo de la página principal
- **Extensión de browser**: instalar la extensión oficial de Wallabag para guardar artículos con un click
- **Modo lectura**: Wallabag elimina ads, sidebars y clutter — solo muestra el texto e imágenes del artículo

---

## Troubleshooting

| Problema | Causa | Solución |
|---|---|---|
| Artículo no carga correctamente | Sitio con paywall o JS pesado | Usar la extensión del browser en vez de pegar la URL |
| `Invalid domain` al acceder | `PI_IP` incorrecto en `.env` | Actualizar `PI_IP` y reiniciar el contenedor |
| Datos perdidos tras recrear contenedor | Volumen eliminado manualmente | Verificar que `wallabag-data` existe con `docker volume ls` |
