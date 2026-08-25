# Pi Services

Servicios propios corriendo en una Raspberry Pi 5: bloqueo de publicidad y DNS de la red, multimedia, automatización de la casa, lectura de noticias, seguimiento de gastos y datos de salud. Casi todo en Docker, con un solo comando para levantarlo y un instalador que además lo configura.

---

## Empezar

```bash
git clone git@github.com:Jerolussich/Pi-Services.git ~/pi-services
cd ~/pi-services && ./instalador.sh
```

El instalador te muestra el estado de cada módulo, te deja elegir cuáles querés (y hasta qué servicios sueltos dentro de cada uno), te pide solo los datos que no puede deducir, y levanta todo.

**Y no se queda en levantar contenedores: los configura.** Deja a Jellyfin con tu usuario y sus bibliotecas, a Radarr y Sonarr apuntando a sus carpetas y hablando con qBittorrent, a Seerr listo para pedir una película con un botón, y hasta te crea las cuentas de FreshRSS y Wallabag con sus claves de API escritas. Todo antes de que abras el navegador.

Podés volver a correrlo cuando quieras: detecta lo que ya funciona y no lo toca.

| | |
|---|---|
| **Cómo funciona por dentro** | [docs/INSTALADOR.md](docs/INSTALADOR.md) |
| **Índice de todo lo demás** | [docs/INDICE.md](docs/INDICE.md) |

---

## Qué hay adentro

Todo entra por Caddy en `http://<nombre>.pi`. Ningún contenedor publica puertos al host, salvo el de torrenting de qBittorrent.

### Multimedia

| Servicio | URL | Qué hace |
|---|---|---|
| Jellyfin | `jellyfin.pi` | Reproduce películas y series |
| Seerr | `seerr.pi` | Pedir contenido: buscás, apretás un botón y aparece |
| Radarr | `radarr.pi` | Automatiza películas |
| Sonarr | `sonarr.pi` | Automatiza series, con temporadas y calendario |
| Prowlarr | `prowlarr.pi` | Gestor central de indexers |
| Bazarr | `bazarr.pi` | Subtítulos automáticos |
| qBittorrent | `qbit.pi` | Cliente de descargas |

El contenido vive en un DAS de dos discos unidos con mergerfs. Detalle en [media/README.md](media/README.md) y [media/DAS.md](media/DAS.md).

### Casa

| Servicio | URL | Qué hace |
|---|---|---|
| Home Assistant | `casa.pi` | Automatizar luces, sensores y enchufes |

Es el único contenedor en la red del host, porque descubre dispositivos por mDNS y SSDP. Por qué eso no rompe la arquitectura, en [home/README.md](home/README.md).

### Red y panel

| Servicio | URL | Qué hace |
|---|---|---|
| Pi-hole | `pihole.pi` | DNS de la red, bloqueo de publicidad, resuelve los `*.pi` |
| Caddy | interno | Proxy inverso: todo el tráfico HTTP entra por acá |
| Homepage | `homepage.pi` | Panel de inicio, con datos en vivo de cada servicio |
| Eventos | `eventos.pi` | Feed de lo que fue pasando. Sin servicio detrás: un archivo estático |
| Tailscale | interno | Acceso remoto sin abrir puertos en el router |

### Monitoreo

| Servicio | URL | Qué hace |
|---|---|---|
| Grafana | `grafana.pi` | Tableros de métricas, salud y finanzas |
| Prometheus | `prometheus.pi` | Recolección y almacenamiento de métricas |

Más Node Exporter y Pi-hole Exporter, sin interfaz propia. Ver [monitoring/README.md](monitoring/README.md).

### Lectura

| Servicio | URL | Qué hace |
|---|---|---|
| FreshRSS | `freshrss.pi` | Lector de RSS |
| Wallabag | `wallabag.pi` | Guardar artículos para leer después |
| News Filter | `news.pi` | Filtra noticias por palabras clave y guarda las que importan |

Ver [news/README.md](news/README.md).

### Datos personales

| Servicio | URL | Qué hace |
|---|---|---|
| Fitbit Exporter | `fitbit.pi` | Baja tus datos de salud de Fitbit |
| Finance Tracker | `finance.pi` | Lee los mails del banco y arma tus finanzas |

Ver [fitbit-exporter/README.md](fitbit-exporter/README.md) y [finance/finance-tracker/README.md](finance/finance-tracker/README.md).

### Infraestructura

**Ofelia** ([ofelia/README.md](ofelia/README.md)) es el único programador de tareas: dispara trabajos en los demás contenedores según etiquetas, en vez de que cada uno traiga su propio cron.

---

## Lo que corre solo

Cuatro cosas pasan sin que las pidas, y están acá porque son justo las que uno olvida que existen hasta que las necesita.

| | Qué | Cuándo |
|---|---|---|
| **Feed** | lo que no merece interrumpirte pero sí recordarse, en `eventos.pi` | siempre |
| **Respaldo** | [`respaldo.sh`](respaldo.sh) guarda los `.env`, los tokens y todas las bases de datos en `~/respaldos` | todos los días a las 04:00 |
| **Diagnóstico** | [`diagnostico.sh`](diagnostico.sh) revisa todo, avisa, anota y publica métricas a Grafana | cada hora |
| **Límite a los logs** | [`docker/daemon.json`](docker/README.md) acota los logs de Docker, que de fábrica no tienen tope y pueden llenar la tarjeta | siempre |

Los timers los instala y los programa el instalador, desde [`systemd/`](systemd/). **Los horarios y los umbrales se cambian en un solo archivo**, [`ajustes.conf`](ajustes.conf), y no adentro de las unidades ni del código.

### Y una que sí elegís

**Avisos al celular.** Es un módulo del menú del instalador, no algo que pasa solo, porque es lo único de todo el repo que manda algo fuera de tu casa: los títulos de los avisos pasan por ntfy.sh, un servicio público gratuito.

Si lo activás, cada hora el diagnóstico revisa todo y **te avisa solo si algo cambió de estado**. Si no cambió nada, silencio. Y el instalador te deja los pasos para suscribirte, con los nombres a la vista.

```bash
./avisos.sh --canales     # los pasos, con tus nombres
./avisos.sh --probar      # una prueba a cada canal
./avisos.sh --apagar      # dejar de recibirlos, sin borrar los canales
./avisos.sh               # el feed de eventos
```

El detalle, en [docs/AVISOS.md](docs/AVISOS.md).

**Falta un paso que es tuyo:** bajarte una copia del respaldo. Mientras viva en la misma tarjeta, no es un respaldo.

```bash
scp jlussich@192.168.68.66:~/respaldos/pi-respaldo-*.tar.gz .
```

---

## Uso diario

Después de un reinicio **no hay nada que hacer**: Pi-hole y Tailscale son servicios del sistema, y los contenedores tienen `restart: unless-stopped`.

| Acción | Comando |
|---|---|
| Levantar todo | `docker compose up -d` |
| Bajar todo | `docker compose down` |
| Recrear un servicio | `docker compose up -d --force-recreate <servicio>` |
| Reconstruir tras cambiar código | `docker compose up -d --build <servicio>` |
| Ver el estado | `docker compose ps` |
| Ver qué anda mal y por qué | `./diagnostico.sh` |

El detalle está en [docs/OPERACION.md](docs/OPERACION.md).

---

## Cómo está armado

Tres decisiones explican casi todo, y están desarrolladas en [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md):

**Nada se expone directamente.** Ningún contenedor publica puertos. Todo el HTTP entra por Caddy en el 80 y se reparte por nombre. Un solo lugar donde mirar quién entra y donde poner autenticación.

**Los nombres los resuelve Pi-hole.** Cada servicio tiene su `*.pi`. Por eso Pi-hole no es solo un bloqueador: es de lo que depende que funcionen los nombres de toda la infraestructura.

**Un solo compose levanta todo.** El `docker-compose.yml` de la raíz no define servicios: los incluye desde cada carpeta. Un `docker compose up -d` levanta los 23, y `cd media && docker compose up -d` levanta solo ese módulo.

### Y se mantiene solo

Cada dato vive en un solo lugar y el resto se deriva. Los registros DNS de Pi-hole, el puerto interno de cada servicio y los puertos que hay que abrirle a Caddy en el firewall **salen todos del Caddyfile**. Agregar un servicio es agregar su bloque ahí; lo demás se acomoda la próxima vez que corras el instalador.

Las API keys tampoco se copian: el instalador las lee de cada servicio y las escribe donde hacen falta.

Y lo mismo con el tiempo: **los horarios de las tareas automáticas salen de [`ajustes.conf`](ajustes.conf)**, no de las unidades de systemd. Cambiás una línea ahí, volvés a correr el instalador, y las unidades se reescriben solas.

---

## Estructura

```
pi-services/
├── instalador.sh              ← levanta y configura, por modulos
├── diagnostico.sh             ← que anda, que no, y por que
├── avisos.sh                  ← el feed de eventos y los avisos al celular
├── respaldo.sh                ← respaldo diario de lo irrecuperable
├── setup-security.sh          ← UFW y fail2ban
├── ajustes.conf               ← horarios y umbrales, el unico lugar donde se tocan
├── docker-compose.yml         ← incluye todos los servicios
├── lib/comun.sh               ← lo que el instalador y el diagnostico saben en comun
├── lib/avisos.sh              ← las cuatro salidas de un hallazgo
├── systemd/                   ← los timers, que instala el instalador
├── docker/                    ← daemon.json, el limite a los logs
├── docs/                      ← toda la documentacion transversal
│
├── caddy/                     ← proxy inverso, la puerta de entrada
├── homepage/                  ← panel de inicio
├── monitoring/                ← Prometheus, Grafana y exporters
├── media/                     ← Jellyfin, Seerr, Radarr, Sonarr, Prowlarr, Bazarr, qBittorrent
├── home/                      ← Home Assistant
├── news/                      ← FreshRSS, Wallabag, news-filter
├── finance/                   ← lector de mails del banco
├── fitbit-exporter/           ← datos de salud
├── ofelia/                    ← programador de tareas
└── calibre/                   ← DESINSTALADO, queda como referencia
```

Cada carpeta de servicio sigue el mismo patrón: `docker-compose.yml`, un `.env` que nunca se versiona, un `.env.example` como plantilla, y un `README.md` que explica qué hace y cómo configurarlo.

---

## Seguridad

Es un despliegue de red local, con defensa en capas y **nada publicado a internet**: el router no tiene un solo puerto abierto hacia el Pi.

| Capa | Qué hace |
|---|---|
| **Caddy** | Punto único de entrada HTTP, con autenticación básica para los servicios que no traen la suya |
| **UFW** | Solo deja entrar 22, 80 y 53. Los puertos del host quedan cerrados salvo para Caddy |
| **fail2ban** | Banea una hora tras 5 intentos fallidos, en SSH y en la autenticación de Caddy |
| **Tailscale** | Acceso remoto sin abrir puertos |

```bash
./setup-security.sh --dry-run    # muestra todo lo que haria, sin hacer nada
./setup-security.sh              # lo aplica
```

Detecta los puertos de los servicios que estén corriendo, ofrece desactivar lo que no usás (VNC, rpcbind), y configura UFW y fail2ban. Tu LAN y tu tailnet quedan exentas del baneo, porque si no el que termina afuera sos vos.

### Archivos sensibles

Nunca se commitean, y están en `.gitignore`. Son también **lo primero que hay que respaldar**, porque son lo único que no se puede volver a generar:

- todos los `**/.env` — contraseñas de los servicios
- `caddy/.env` — el hash bcrypt de la autenticación básica
- `fitbit-exporter/tokens.json` — credenciales de OAuth de Fitbit
- `finance/finance-tracker/data/token.json` y `config.json` — tokens de Microsoft y el secreto de Azure

---

## Más documentación

| Tema | Documento |
|---|---|
| Índice de todo | [docs/INDICE.md](docs/INDICE.md) |
| Cómo funciona el instalador | [docs/INSTALADOR.md](docs/INSTALADOR.md) |
| Decisiones de diseño y por qué | [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md) |
| Levantar, bajar, actualizar, logs | [docs/OPERACION.md](docs/OPERACION.md) |
| Avisos al celular, feed y métricas | [docs/AVISOS.md](docs/AVISOS.md) |
| Salud del equipo y la tarjeta | [docs/MANTENIMIENTO.md](docs/MANTENIMIENTO.md) |
| Acceso remoto | [TAILSCALE.md](TAILSCALE.md) |
| Qué pasó el 20 de agosto de 2026 | [docs/INCIDENTE-2026-08-20.md](docs/INCIDENTE-2026-08-20.md) |

Y cada servicio tiene el suyo, con el detalle técnico y los problemas conocidos.
