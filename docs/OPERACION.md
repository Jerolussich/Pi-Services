# Operación

Cómo levantar, bajar, configurar y diagnosticar. Todo lo del día a día.

---

## Levantar todo

```bash
cd ~/pi-services && docker compose up -d
```

Eso levanta los 23 servicios, incluidos el stack multimedia y Home Assistant. Un solo comando, una sola mecánica.

**En una instalación desde cero, antes hay que crear la red una vez:**

```bash
docker network create pi-services
```

Ocho de los compose la declaran como `external: true`, porque están pensados para poder levantarse sueltos. Eso significa que esperan que ya exista, y en un equipo nuevo no existe. Si te salteás este paso, el `up` construye todas las imágenes y recién al final falla con `network pi-services declared as external, but could not be found`, sin levantar nada.

Solo hace falta la primera vez: la red sobrevive a `docker compose down`, y como se creó a mano no lleva etiquetas de Compose, así que Compose no la considera suya y no la borra.

**El instalador se encarga de esto solo**, y lo comprueba antes de cada módulo, no una sola vez. Así da lo mismo que levantes dos módulos hoy y tres el mes que viene.

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

Esto es seguro porque **todos los compose fijan `name: pi-services`** en su primera línea. Sin eso, Compose usa el nombre de la carpeta como nombre de proyecto, y los volúmenes pasarían a llamarse `monitoring_grafana-data` en vez de `pi-services_grafana-data`. El servicio arrancaría vacío, como recién instalado, y los datos viejos quedarían en un volumen huérfano ocupando espacio. Es un modo de fallar especialmente feo porque parece pérdida de datos y no lo es.

Por el mismo motivo el repo puede vivir en una carpeta con cualquier nombre: sin el `name:` fijo, clonarlo como `Pi-Services` en vez de `pi-services` bastaría para que todo apareciera vacío.

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

### Ya corre solo

Hay un timer de systemd que respalda **todos los días a las 4 de la mañana** y guarda los últimos 7 en `~/respaldos`. Cada uno pesa menos de medio mega, así que una semana entera ocupa menos que una foto.

```bash
systemctl list-timers pi-respaldo
```

Para hacer uno ahora mismo:

```bash
cd ~/pi-services && ./respaldo.sh
```

Y para ver qué capturaría sin hacer nada:

```bash
cd ~/pi-services && ./respaldo.sh --listar
```

### Qué entra

Lo irrecuperable, que son unos pocos megas: los 10 `.env` con contraseñas y claves de API, los tokens de OAuth, y las 8 bases de datos, tanto las del repo como las que viven dentro de los volúmenes de Docker.

No entra lo que se reconstruye solo: imágenes, la caché de Jellyfin, el histórico de Prometheus, ni nada que ya esté en GitHub. Meterlo multiplicaría el tamaño por cien sin salvar nada que importe.

**Las bases se copian con la API de SQLite, no con `cp`.** Copiar un `.db` en caliente puede dar un archivo roto, porque SQLite escribe en un WAL aparte y lo une después. La API de respaldo da una copia consistente aunque el servicio esté escribiendo en ese momento.

**Y se arma en `/tmp`, que es RAM.** Un respaldo que desgasta el medio que intenta proteger es un mal negocio, y encima corre justo cuando el disco puede estar por llenarse.

### Falta el paso que importa

Todo lo anterior sigue viviendo en la misma tarjeta que puede morir. Bajate una copia a tu PC:

```bash
scp jlussich@192.168.68.66:~/respaldos/pi-respaldo-*.tar.gz .
```

Adentro del `.tar.gz` hay un `MANIFIESTO.txt` con qué contiene y los pasos exactos para restaurarlo, incluida la parte de meter las bases de vuelta en los volúmenes de Docker, que es la que menos se acuerda uno.

**Un respaldo sin restaurar es una suposición.** El script verifica que el archivo se pueda leer, pero eso no prueba que restaure bien. La única prueba de verdad es probarlo.
