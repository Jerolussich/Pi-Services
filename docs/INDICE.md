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

## Uso diario

Después de un reinicio **no hay nada que hacer**: Pi-hole, Tailscale y Calibre son servicios del sistema y arrancan solos, y los contenedores tienen `restart: unless-stopped`.

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
| Calibre | `calibre.pi` | Biblioteca de libros. **Nativo, no Docker** | [../calibre/README.md](../calibre/README.md) |

### Datos personales

| Servicio | URL | Qué hace | Documentación |
|---|---|---|---|
| Fitbit Exporter | `fitbit.pi` | Baja tus datos de salud de Fitbit | [../fitbit-exporter/README.md](../fitbit-exporter/README.md) |
| Finance Tracker | `finance.pi` | Lee los mails del banco y arma tus finanzas | [../finance/finance-tracker/README.md](../finance/finance-tracker/README.md) |

### Multimedia

| Servicio | URL | Qué hace | Documentación |
|---|---|---|---|
| Jellyfin | `jellyfin.pi` | Servidor multimedia | [../media/README.md](../media/README.md) |
| Radarr | `radarr.pi` | Automatiza películas | [../media/README.md](../media/README.md) |
| Prowlarr | `prowlarr.pi` | Gestor de indexers | [../media/README.md](../media/README.md) |
| Bazarr | `bazarr.pi` | Subtítulos automáticos | [../media/README.md](../media/README.md) |
| qBittorrent | `qbit.pi` | Cliente de descargas | [../media/README.md](../media/README.md) |

### Infraestructura interna

| Servicio | Qué hace | Documentación |
|---|---|---|
| Ofelia | Programador de tareas de todos los contenedores | [../ofelia/README.md](../ofelia/README.md) |
| Node Exporter | Métricas del sistema para Prometheus | [../monitoring/README.md](../monitoring/README.md) |
| Pi-hole Exporter | Métricas de Pi-hole para Prometheus | [../monitoring/README.md](../monitoring/README.md) |

---

## Documentos por tema

### Operación

- [OPERACION.md](OPERACION.md): levantar, bajar, actualizar, ver logs, backups
- [ARQUITECTURA.md](ARQUITECTURA.md): cómo encaja todo, decisiones de diseño y por qué

### Multimedia

- [../media/README.md](../media/README.md): el stack completo y su configuración paso a paso
- [../media/DAS.md](../media/DAS.md): los dos discos unidos con mergerfs
- [../media/JELLYFIN-PLUGINS.md](../media/JELLYFIN-PLUGINS.md): plugins, cuáles son nativos y cuáles no
- [PLAN-MEDIA.md](PLAN-MEDIA.md): plan de implementación, con el orden y las dependencias

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
├── caddy/                     ← proxy inverso, la puerta de entrada
├── homepage/                  ← panel de inicio
├── monitoring/                ← Prometheus, Grafana y exporters
├── media/                     ← Jellyfin, Radarr, Prowlarr, Bazarr, qBittorrent
├── news/                      ← FreshRSS, Wallabag, news-filter
├── finance/                   ← lector de mails del banco
├── fitbit-exporter/           ← datos de salud
├── ofelia/                    ← programador de tareas
└── calibre/                   ← biblioteca de libros (nativo, no Docker)
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
