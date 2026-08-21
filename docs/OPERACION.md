# Operación

Cómo levantar, bajar, configurar y diagnosticar. Todo lo del día a día.

---

## Levantar todo

```bash
cd ~/pi-services && docker compose up -d
```

Eso levanta los 20 servicios, incluido el stack multimedia. Un solo comando, una sola mecánica.

**En una instalación desde cero, antes hay que crear la red una vez:**

```bash
docker network create pi-services
```

Tres servicios (`homepage`, `wallabag` y `finance-tracker`) la declaran como `external: true`, porque están pensados para poder levantarse sueltos. Eso significa que esperan que ya exista, y en un equipo nuevo no existe. Si te salteás este paso, el `up` construye todas las imágenes y recién al final falla con `network pi-services declared as external, but could not be found`, sin levantar nada.

Solo hace falta la primera vez: la red sobrevive a `docker compose down`.

## Bajar todo

```bash
cd ~/pi-services && docker compose down
```

No borra datos: los volúmenes y las carpetas `data/` quedan intactos. Para borrar también los volúmenes hay que agregar `-v` a propósito, y eso te deja empezando de cero.

## Un solo servicio

Cada carpeta funciona por su cuenta:

```bash
cd ~/pi-services/monitoring && docker compose up -d
```

O desde la raíz, nombrándolo:

```bash
cd ~/pi-services && docker compose up -d grafana
```

## Reiniciar uno

```bash
docker restart grafana
```

## Ver qué está corriendo

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

## Ver logs

```bash
docker logs -f caddy
```

Las últimas 50 líneas de uno puntual:

```bash
docker logs --tail 50 radarr
```

---

## Configurar un servicio nuevo

Siempre el mismo procedimiento, sea cual sea el servicio:

**1. Copiar la plantilla de variables.**

```bash
cd ~/pi-services/<servicio> && cp .env.example .env
```

**2. Completar `.env`.** Cada variable está comentada en el `.env.example` con cómo obtener su valor. Ninguno de estos archivos se sube a git.

**3. Leer el README de esa carpeta.** Varios servicios necesitan pasos de una sola vez que no se pueden automatizar: registrar una aplicación en Fitbit, autorizar el acceso al correo, cargar el registro DNS en Pi-hole.

**4. Levantar.**

```bash
docker compose up -d
```

---

## Agregar un servicio al Pi

Cuatro pasos, en este orden:

**1. Creá la carpeta** con `docker-compose.yml`, `.env.example` y `README.md`, siguiendo el patrón de cualquier servicio existente.

**2. Agregalo al `include:`** del `docker-compose.yml` de la raíz.

**3. Agregá la entrada en `caddy/Caddyfile`:**

```
http://nuevo.pi {
    import accesslog
    reverse_proxy nuevo:1234
}
```

El `import accesslog` no es opcional: es lo que hace que fail2ban vea los intentos fallidos contra ese servicio.

**4. Creá el registro DNS** en Pi-hole, en `Local DNS → DNS Records`, apuntando `nuevo.pi` a `192.168.68.66`.

Sin el paso 4 el nombre no resuelve y vas a ver un error de DNS, no de Caddy.

---

## Actualizar imágenes

```bash
cd ~/pi-services && docker compose pull && docker compose up -d
```

Descarga las versiones nuevas y recrea solo los contenedores que cambiaron.

Después conviene limpiar lo que quedó suelto:

```bash
docker image prune -f
```

Un aviso: `wallabag` está fijado a la versión `2.6.13` a propósito. Si lo desfijás, `pull` va a traer la última y podés encontrarte con una migración de base de datos no deseada.

---

## Verificar que todo anda

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://homepage.pi
```

Debería devolver `401`, que significa que Caddy está pidiendo autenticación, o sea que funciona.

Estado del firewall:

```bash
sudo ufw status verbose
```

Estado de fail2ban:

```bash
sudo fail2ban-client status
```

Espacio en disco, que es lo que más conviene mirar seguido:

```bash
df -h /
```

---

## Diagnóstico rápido

| Síntoma | Qué mirar primero |
|---|---|
| Un nombre `.pi` no resuelve | Falta el registro DNS en Pi-hole, o Pi-hole está caído |
| Un `.pi` resuelve pero da 502 | El contenedor de destino no está corriendo: `docker ps` |
| Todo el HTTP caído | Caddy: `docker logs caddy`. Puede ser un error de sintaxis en el Caddyfile |
| No entrás por SSH | Ver [MANTENIMIENTO.md](MANTENIMIENTO.md), sección de recuperación |
| Un contenedor reinicia en bucle | `docker logs --tail 50 <nombre>` |
| Disco lleno | `sudo du -xsh /var/log/* \| sort -rh \| head` |

Antes de cambiar el Caddyfile conviene validarlo, así no te quedás sin HTTP por un error de tipeo:

```bash
docker run --rm -v ~/pi-services/caddy/Caddyfile:/etc/caddy/Caddyfile:ro -v ~/pi-services/caddy/.env:/etc/caddy/.env:ro caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile --envfile /etc/caddy/.env
```

---

## Backups: qué respaldar

Esto es lo importante y lo que más fácil se olvida. **Nada de lo que está en `.gitignore` se va a GitHub**, así que subir el repo no te respalda lo que más duele perder.

Lo que hay que copiar afuera del Pi:

| Qué | Dónde está |
|---|---|
| Contraseñas y tokens | todos los `.env`, más `fitbit-exporter/tokens.json` y `finance/finance-tracker/data/token.json` |
| Bases de datos | `fitbit-exporter/exports/fitbit.db`, `finance/finance-tracker/data/finance.db`, `news/news-filter/data/seen.db` |
| Estado de los contenedores | los volúmenes de Docker: Grafana, Wallabag, FreshRSS, Prometheus |
| Biblioteca de libros | `~/calibre-library` |

Un respaldo de los archivos chicos:

```bash
cd ~ && tar czf ~/pi-backup-$(date +%F).tar.gz $(find pi-services -name ".env" -o -name "tokens.json" -o -name "*.db" | grep -v venv)
```

Y de los volúmenes:

```bash
docker run --rm -v monitoring_grafana-data:/data -v ~/docker-volumes-backup:/backup alpine tar czf /backup/grafana-$(date +%F).tar.gz -C /data .
```

Copiá el resultado **fuera del Pi**. Un backup que vive en el mismo disco que se puede corromper no es un backup.
