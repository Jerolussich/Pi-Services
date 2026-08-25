# Índice

Punto de entrada del repositorio. Desde acá llegás a cualquier cosa sin tener que recorrer carpetas.

---

## Empezar de cero

Grabá Raspberry Pi OS **Lite de 64 bits**, entrá por SSH, cloná el repo y corré:

```bash
./instalador.sh
```

Te muestra el estado de cada módulo, elegís cuáles querés (y hasta qué servicios sueltos dentro de cada uno), te pide los datos que necesita explicándote de dónde sacarlos, y levanta todo. Lo que no tengas a mano lo salteás y al final te dice exactamente qué quedó sin completar.

**Podés volver a correrlo cuando quieras** para sumar un módulo, completar un dato que salteaste o levantar un servicio que dejaste apagado. Detecta lo que ya funciona y no lo toca.

Cómo funciona por dentro: [INSTALADOR.md](INSTALADOR.md).

Si preferís entender antes de ejecutar, o hacerlo a mano:

| Para | Documento |
|---|---|
| Entender qué es cada cosa y por qué | [ARQUITECTURA.md](ARQUITECTURA.md) |
| Levantar, bajar y diagnosticar | [OPERACION.md](OPERACION.md) |
| Configurar cada servicio | el README de cada uno, abajo |
| Acceso remoto | [../TAILSCALE.md](../TAILSCALE.md) |
| Que no se vuelva a romper | [MANTENIMIENTO.md](MANTENIMIENTO.md) |
| Diagnosticar un problema | `./diagnostico.sh`, ver abajo |
| Respaldos y logs | la sección de acá abajo |

## Uso diario

Después de un reinicio **no hay nada que hacer**: Pi-hole y Tailscale son servicios del sistema y arrancan solos, y los contenedores tienen `restart: unless-stopped`.

Si igual querés levantar todo a mano, es un solo comando:

```bash
cd ~/pi-services && docker compose up -d
```

---

## Los servicios

Todo entra por Caddy en `http://<nombre>.pi`. Ningún contenedor publica puertos al host, salvo el de torrenting de qBittorrent.

### Red y acceso

| Servicio | URL | Qué hace | Documentación |
|---|---|---|---|
| Pi-hole | `pihole.pi` | DNS de la red y bloqueo de publicidad. Resuelve los nombres `*.pi` | nativo, no está en este repo |
| Caddy | interno | Proxy inverso: todo el tráfico HTTP entra por acá | [../caddy/README.md](../caddy/README.md) |
| Tailscale | interno | Acceso remoto sin abrir puertos | [../TAILSCALE.md](../TAILSCALE.md) |

### Panel y monitoreo

| Servicio | URL | Qué hace | Documentación |
|---|---|---|---|
| Homepage | `homepage.pi` | Panel de inicio con enlaces a todo | [../homepage/README.md](../homepage/README.md) |
| Grafana | `grafana.pi` | Tableros de métricas | [../monitoring/README.md](../monitoring/README.md) |
| Prometheus | `prometheus.pi` | Recolección y almacenamiento de métricas | [../monitoring/README.md](../monitoring/README.md) |

### Lectura

| Servicio | URL | Qué hace | Documentación |
|---|---|---|---|
| FreshRSS | `freshrss.pi` | Lector de RSS | [../news/README.md](../news/README.md) |
| Wallabag | `wallabag.pi` | Guardar artículos para leer después | [../news/wallabag/README.md](../news/wallabag/README.md) |
| News Filter | `news.pi` | Filtra noticias por palabras clave | [../news/README.md](../news/README.md) |

### Datos personales

| Servicio | URL | Qué hace | Documentación |
|---|---|---|---|
| Fitbit Exporter | `fitbit.pi` | Baja tus datos de salud de Fitbit | [../fitbit-exporter/README.md](../fitbit-exporter/README.md) |
| Finance Tracker | `finance.pi` | Lee los mails del banco y arma tus finanzas | [../finance/finance-tracker/README.md](../finance/finance-tracker/README.md) |

### Multimedia

| Servicio | URL | Qué hace | Documentación |
|---|---|---|---|
| Jellyfin | `jellyfin.pi` | Servidor multimedia | [../media/README.md](../media/README.md) |
| Seerr | `seerr.pi` | Pedir películas y series: buscás, apretás un botón y aparece | [../media/README.md](../media/README.md) |
| Radarr | `radarr.pi` | Automatiza películas | [../media/README.md](../media/README.md) |
| Sonarr | `sonarr.pi` | Automatiza series, con temporadas y calendario | [../media/README.md](../media/README.md) |
| Prowlarr | `prowlarr.pi` | Gestor de indexers | [../media/README.md](../media/README.md) |
| Bazarr | `bazarr.pi` | Subtítulos automáticos | [../media/README.md](../media/README.md) |
| qBittorrent | `qbit.pi` | Cliente de descargas | [../media/README.md](../media/README.md) |

### Casa

| Servicio | URL | Qué hace | Documentación |
|---|---|---|---|
| Home Assistant | `casa.pi` | Automatizar luces, sensores y enchufes de la casa | [../home/README.md](../home/README.md) |

### Infraestructura interna

| Servicio | Qué hace | Documentación |
|---|---|---|
| Ofelia | Programador de tareas de todos los contenedores | [../ofelia/README.md](../ofelia/README.md) |
| Node Exporter | Métricas del sistema para Prometheus | [../monitoring/README.md](../monitoring/README.md) |
| Pi-hole Exporter | Métricas de Pi-hole para Prometheus | [../monitoring/README.md](../monitoring/README.md) |

---

## Lo que corre solo

Cinco cosas pasan sin que las pidas. Están acá porque son justamente las que uno olvida que existen hasta que las necesita.

Todas las instala y las programa el instalador. Los horarios salen de [`ajustes.conf`](../ajustes.conf), un solo archivo, y no de las unidades de systemd.

### Avisos al celular

Este **se elige**: es el módulo `Avisos` del menú del instalador, y no algo que pasa solo. Es lo único del repo que manda algo fuera de tu casa (los títulos pasan por ntfy.sh), así que se pregunta antes de crear nada.

Si lo activás: cada hora el diagnóstico revisa todo y, **si algo cambió de estado**, te llega una notificación al teléfono. Si no cambió nada, silencio. Son dos canales, `alertas` (suena, casi nunca habla) y `media` (silencioso, avisa cuando una película o una serie está lista).

```bash
./avisos.sh --canales     # los pasos para suscribirte, con tus nombres
./avisos.sh --probar      # una prueba a cada canal
./avisos.sh --apagar      # dejar de recibirlos, sin borrar los canales
```

Todo el detalle en [AVISOS.md](AVISOS.md).

### Feed de eventos

Lo que no merece interrumpirte pero sí recordarse: el respaldo que salió bien, la revisión de discos, las importaciones de anoche. En **`http://eventos.pi`** o con `./avisos.sh`.

No hay ningún servicio detrás: Caddy sirve una página estática y un archivo de texto que escribe el diagnóstico.

### Respaldo diario

| | |
|---|---|
| Qué corre | [`respaldo.sh`](../respaldo.sh) |
| Cuándo | todos los días a las **04:00** |
| Quién lo dispara | el timer `pi-respaldo` ([`systemd/`](../systemd/)) |
| Dónde deja el archivo | **`~/respaldos`** en la Pi, guarda los últimos 7 |
| Cuánto pesa | poco más de 1 MB cada uno |

Guarda lo irrecuperable y nada más: los `.env` con contraseñas y claves, los tokens de OAuth, y las bases de datos de cada servicio, incluidas las que viven dentro de los volúmenes de Docker.

```bash
systemctl list-timers pi-respaldo        # cuándo corre la próxima
cd ~/pi-services && ./respaldo.sh        # uno ahora mismo
cd ~/pi-services && ./respaldo.sh --listar   # qué capturaría
```

**Falta un paso que es tuyo:** bajarte una copia. Mientras viva en la misma tarjeta, no es un respaldo.

```bash
scp jlussich@192.168.68.66:~/respaldos/pi-respaldo-*.tar.gz .
```

Adentro de cada `.tar.gz` hay un `MANIFIESTO.txt` con los pasos de restauración. El detalle completo está en [OPERACION.md](OPERACION.md).

### Aviso al entrar por SSH

Cada hora corre el diagnóstico y deja el resultado en `/run`, que es RAM. Cuando entrás por SSH, si hay algo mal te lo muestra; si está todo bien, no molesta. Lo dispara el timer `pi-estado`, el mismo que manda los avisos y publica las métricas.

### Límite a los logs

Docker guarda los logs de cada contenedor **sin ningún límite de fábrica**. Un contenedor en bucle de reinicio puede escribir toda la noche y llenar la tarjeta, y una tarjeta llena corrompe bases de datos al escribir.

Está acotado en [`docker/daemon.json`](../docker/daemon.json): 5 MB por archivo, 3 archivos, o sea 15 MB por contenedor y unos 315 MB de techo entre todos. El journal de systemd tiene su propio tope de 100 MB.

El porqué y los detalles, en [../docker/README.md](../docker/README.md).

```bash
du -sh /var/lib/docker/containers    # cuánto ocupan hoy
journalctl --disk-usage              # y el journal
```

---

## Documentos por tema

### Operación

- [OPERACION.md](OPERACION.md): levantar, bajar, actualizar, ver logs, backups
- [ARQUITECTURA.md](ARQUITECTURA.md): cómo encaja todo, decisiones de diseño y por qué
- [AVISOS.md](AVISOS.md): notificaciones al celular, feed de eventos, métricas propias y el score de salud

### Multimedia

- [../media/README.md](../media/README.md): el stack completo y su configuración paso a paso
- [../media/DAS.md](../media/DAS.md): los dos discos unidos con mergerfs
- [../media/JELLYFIN-PLUGINS.md](../media/JELLYFIN-PLUGINS.md): plugins, cuáles son nativos y cuáles no
- [PLAN-MEDIA.md](PLAN-MEDIA.md): plan de implementación, con el orden y las dependencias

### Casa

- [../home/README.md](../home/README.md): Home Assistant, por qué es el único en la red del host y qué deja hecho el instalador

### Mantenimiento

- [MANTENIMIENTO.md](MANTENIMIENTO.md): salud del Pi, corrupción de la SD, backups y endurecimiento
- [INCIDENTE-2026-08-20.md](INCIDENTE-2026-08-20.md): qué pasó el 20 de agosto de 2026, la causa raíz y todo lo que se reparó

---

## Dónde está cada cosa

```
pi-services/
├── docs/                      ← estás acá
├── docker-compose.yml         ← agrega todos los servicios con include
├── setup-security.sh          ← UFW y fail2ban
├── TAILSCALE.md
│
├── respaldo.sh                ← respaldo diario de lo irrecuperable
├── diagnostico.sh             ← que anda, que no, y por que
├── avisos.sh                  ← el feed de eventos y los avisos al celular
├── ajustes.conf               ← horarios y umbrales, el unico lugar donde se tocan
├── lib/comun.sh               ← lo que el instalador y el diagnostico saben en comun
├── lib/avisos.sh              ← las cuatro salidas de un hallazgo
├── systemd/                   ← los timers, que instala el instalador
├── docker/                    ← daemon.json, el limite a los logs
│
├── caddy/                     ← proxy inverso, la puerta de entrada
├── homepage/                  ← panel de inicio
├── monitoring/                ← Prometheus, Grafana y exporters
├── media/                     ← Jellyfin, Seerr, Radarr, Sonarr, Prowlarr, Bazarr, qBittorrent
├── home/                      ← Home Assistant, la automatizacion de la casa
├── news/                      ← FreshRSS, Wallabag, news-filter
├── finance/                   ← lector de mails del banco
├── fitbit-exporter/           ← datos de salud
├── ofelia/                    ← programador de tareas
```

Cada carpeta de servicio sigue el mismo patrón:

```
<servicio>/
├── docker-compose.yml
├── .env                       ← nunca se versiona
├── .env.example               ← plantilla con las variables que hacen falta
└── README.md                  ← qué hace y cómo configurarlo
```

Si abrís una carpeta que no conocés, el `README.md` de adentro te dice todo. Si querés saber qué variables necesita, mirá el `.env.example`.
