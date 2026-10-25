# Operación

Cómo levantar, bajar, configurar y diagnosticar. Todo lo del día a día.

---

## Levantar todo

```bash
cd ~/pi-services && docker compose up -d
```

Eso levanta los 24 servicios, incluidos el stack multimedia (con FlareSolverr) y Home Assistant. Un solo comando, una sola mecánica.

**En una instalación desde cero, antes hay que crear la red una vez:**

```bash
docker network create pi-services
docker network create pi-torrent
```

Son dos: `pi-services`, la de siempre, que diez de los compose declaran como `external: true`, y `pi-torrent`, la red aparte de qBittorrent, que declaran igual `media`, `caddy` y `homepage` (ver [TORRENTS.md](TORRENTS.md)). Los compose están pensados para poder levantarse sueltos, y por eso esperan que las redes ya existan, y en un equipo nuevo no existen. Si te salteás este paso, el `up` construye todas las imágenes y recién al final falla con `network pi-services declared as external, but could not be found`, sin levantar nada.

Solo hace falta la primera vez: las redes sobreviven a `docker compose down`, y como se crearon a mano no llevan etiquetas de Compose, así que Compose no las considera suyas y no las borra.

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

Tres pasos a mano y uno que se hace solo, en este orden:

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

**4. Corré `./instalador.sh`** (o `./diagnostico.sh --arreglar`). El registro DNS de `nuevo.pi` **no se carga a mano**: el instalador lo deriva del Caddyfile, igual que los demás, y el diagnóstico detecta si falta y lo repone. Sin ese registro el nombre no resuelve y vas a ver un error de DNS, no de Caddy.

Si además querés que el instalador y el diagnóstico conozcan el servicio (que lo ofrezcan al elegir módulos, lo revisen y lo tengan en cuenta como dependencia), hay que sumarlo en `lib/comun.sh`: a `SERVICIOS` (con su módulo), a `QUE_HACE` y, si depende de otro, a `DEPENDENCIAS`. Son los únicos lugares que se tocan además del Caddyfile (ver [ARQUITECTURA.md](ARQUITECTURA.md#qué-sigue-sin-derivarse)).

---

## Actualizar imágenes

El camino recomendado es mirar primero y decidir después:

```bash
pi actualizar --ver     # qué hay de nuevo, sin bajar ni tocar nada
pi actualizar           # lo mismo, y te ofrece actualizar de a uno
```

Es que casi todas las imágenes están en `:latest` o `:stable`, y eso suena a que no hay nada que decidir y es al revés: se actualizan solas, sin avisar, **la próxima vez que alguien recree un contenedor por cualquier otro motivo**. `pi actualizar` lo da vuelta. Compara la huella de la imagen que tenés contra la publicada, sin descargar nada (la etiqueta no alcanza: el `:latest` de hace seis meses y el de hoy se llaman igual); para cada novedad te dice qué versión tenés, si la imagen la declara, y adónde mirar los cambios; y actualiza **de a uno, solo lo que le digas que sí** (Enter es no). Después de cada uno comprueba que el contenedor haya vuelto a levantar. Las imágenes que se construyen acá (los seis servicios propios de noticias, finanzas y Fitbit) no se comparan: no vienen de ningún registro.

Lo que no hace es deshacer. Las bases de datos de varios servicios se migran al arrancar la versión nueva y hacia atrás no migran, y por eso pregunta antes y avisa.

La forma de siempre sigue andando:

```bash
cd ~/pi-services && docker compose pull && docker compose up -d
```

Descarga las versiones nuevas y recrea solo los contenedores que cambiaron. Después conviene limpiar lo que quedó suelto:

```bash
docker image prune -f
```

### Qué versión corre cada cosa

| Qué | Cómo está | Por qué |
|---|---|---|
| **Seerr** | **Fijado** en `ghcr.io/seerr-team/seerr:v3.5.1` | El proyecto se llamaba Jellyseerr y se renombró. La imagen vieja (`fallenbagel/jellyseerr`) sigue existiendo, baja sin error y quedó congelada en agosto de 2025: no falla, te deja un año atrás. Con la versión fijada, un `pull` no cambia nada hasta que vos subas el número |
| **Home Assistant** | `:stable` | Estuvo fijado en una versión y el pin terminó mintiendo: el archivo decía una y el contenedor corría otra, porque se había levantado con `:stable`. El peligro era el inverso de lo que suena: el primer `up -d` de rutina iba a **bajar** Home Assistant tres meses sobre una configuración ya escrita por la versión nueva, y hacia atrás no migra. El detalle está comentado en `home/docker-compose.yml` |
| **Todo lo demás** (Jellyfin, qBittorrent, Prowlarr, Radarr, Sonarr, Bazarr, FlareSolverr, Grafana, Prometheus, node-exporter, el exporter de Pi-hole, FreshRSS, Wallabag, Homepage, Caddy, Ofelia) | `:latest`, la rama o sin etiqueta | Se actualizan con `pull` + `up -d`, o mejor con `pi actualizar` |

Para subir Seerr: cambiar la etiqueta en `media/docker-compose.yml`, mirar los cambios del proyecto y `docker compose up -d seerr`. `pi actualizar` igual le avisa si dentro de la misma etiqueta hay una imagen más nueva.

**`wallabag` no está fijado**: su compose usa `wallabag/wallabag` sin etiqueta, o sea `latest`. Un `pull` puede traer una migración de base de datos que no esperabas, así que conviene actualizarlo con `pi actualizar` y mirando antes los cambios.

Un ejemplo de por qué mirar: al actualizar todo el stack, Jellyfin saltó de la 10.11 a la 12, y la 12 sacó cosas de la API de las que dependía el recuadro de la homepage. Está en [../media/README.md](../media/README.md#jellyfin-12-lo-que-cambió-y-lo-que-se-rompió).

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
| qBittorrent no conecta con pares, o dudás de si el puerto está abierto | `pi puerto`: dice si está abierto, si se ve desde internet y si el aislamiento sigue en pie. Ver [TORRENTS.md](TORRENTS.md) |
| Disco lleno | `sudo du -xsh /var/log/* \| sort -rh \| head` |

Antes de cambiar el Caddyfile conviene validarlo, así no te quedás sin HTTP por un error de tipeo:

```bash
docker run --rm -v ~/pi-services/caddy/Caddyfile:/etc/caddy/Caddyfile:ro -v ~/pi-services/caddy/.env:/etc/caddy/.env:ro caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile --envfile /etc/caddy/.env
```

---

## Backups: qué respaldar

Esto es lo importante y lo que más fácil se olvida. **Nada de lo que está en `.gitignore` se va a GitHub**, así que subir el repo no te respalda lo que más duele perder.

### Ya corre solo

Hay un timer de systemd que respalda **todos los días a las 4 de la mañana** y guarda los últimos 7 en `~/respaldos`. Cada uno pesa unos pocos megas como mucho, así que una semana entera ocupa menos que unas pocas fotos.

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

El timer lo corre con `--callado --avisar --rotar=7 ~/respaldos`. `--callado` imprime una sola línea, `--avisar` manda el aviso solo si algo sale mal (el éxito no notifica: queda en el feed), y `--rotar=N` conserva los últimos N. Sin destino, el archivo va a `/tmp`, que es RAM y se borra al reiniciar, a propósito: te obliga a bajarlo en vez de dejar una copia falsa en el mismo disco.

### Qué entra

Lo irrecuperable, que son unos pocos megas: todos los `.env` con contraseñas y claves de API, los tokens de OAuth, las bases de datos (tanto las del repo como las que viven dentro de los volúmenes de Docker), los archivos de configuración que se editan a mano (el Caddyfile, `keywords.txt`, `prometheus.yml`, `services.yaml` de la homepage y el `config.yaml` de Bazarr) y la historia propia: el feed de eventos, el estado de los avisos y las métricas lentas de `datos/`.

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
