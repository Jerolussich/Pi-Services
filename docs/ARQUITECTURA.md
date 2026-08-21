# Arquitectura

Qué hay adentro del Pi, cómo se conecta, y por qué está armado así.

---

## El mapa

```
                    Internet
                       │
                  ┌────┴────┐
                  │ Router  │  192.168.68.1
                  └────┬────┘
                       │
              ┌────────┴────────┐
              │   Raspberry Pi 5 │  192.168.68.66
              └────────┬─────────┘
                       │
   ┌───────────────────┼───────────────────┐
   │                   │                   │
┌──┴───────┐    ┌──────┴──────┐    ┌───────┴────────┐
│ Pi-hole  │    │    Caddy    │    │   Tailscale    │
│ DNS :53  │    │  HTTP :80   │    │  acceso remoto │
│          │    │             │    │                │
│ resuelve │───▶│  proxy a    │    │  entra sin     │
│  *.pi    │    │  todo       │    │  abrir puertos │
└──────────┘    └──────┬──────┘    └────────────────┘
                       │
        ┌──────────────┼──────────────┬──────────────┐
        │              │              │              │
   ┌────┴────┐   ┌─────┴─────┐  ┌─────┴────┐  ┌──────┴─────┐
   │ Panel y │   │  Lectura  │  │  Datos   │  │ Multimedia │
   │ métricas│   │           │  │personales│  │            │
   └─────────┘   └───────────┘  └──────────┘  └──────┬─────┘
                                                     │
                                                ┌────┴────┐
                                                │   DAS   │
                                                │ 2 discos│
                                                └─────────┘
```

---

## Las tres decisiones que explican todo

### 1. Nada se expone directamente

Ningún contenedor publica puertos al host. **Todo el tráfico HTTP entra por Caddy en el puerto 80** y de ahí se reparte según el nombre que pediste.

La única excepción es el puerto de torrenting de qBittorrent, que necesita recibir conexiones entrantes de otros pares y no puede ir por proxy.

La ventaja práctica: hay un solo lugar donde mirar quién entra, un solo lugar donde poner autenticación, y agregar un servicio nuevo no abre nada nuevo hacia afuera.

### 2. Los nombres los resuelve Pi-hole

Cada servicio tiene un nombre `*.pi` que Pi-hole resuelve a la IP del Pi. Caddy después mira ese nombre y te manda al contenedor correcto.

Por eso Pi-hole no es solo un bloqueador de publicidad: es la pieza de la que depende que funcionen los nombres de toda tu infraestructura. Si Pi-hole se cae, los servicios siguen andando pero no llegás a ellos por nombre.

Los registros se cargan en Pi-hole, en `Local DNS → DNS Records`, todos apuntando a `192.168.68.66`.

### 3. Un solo compose levanta todo

El `docker-compose.yml` de la raíz no define servicios: los **incluye** desde cada carpeta. Eso permite dos cosas a la vez:

```bash
docker compose up -d          # desde la raiz: levanta los 20 servicios
```

```bash
cd media && docker compose up -d    # desde una carpeta: levanta solo eso
```

Todos comparten la red `pi-services`, así que se ven entre ellos por nombre de contenedor. Por eso en el Caddyfile aparece `reverse_proxy grafana:3000` y no una IP.

---

## Autenticación: dos criterios

No todos los servicios se protegen igual, y la regla es simple:

**Si el servicio trae login propio, Caddy solo hace de proxy.** Es el caso de Grafana, Wallabag, FreshRSS, Jellyfin, Radarr, Prowlarr, Bazarr y qBittorrent.

**Si no trae login, Caddy le pone autenticación básica adelante.** Es el caso de Homepage, Prometheus y Calibre.

La contraseña de esa autenticación básica vive como hash bcrypt en `caddy/.env`, nunca en texto plano y nunca versionada.

---

## Las capas de defensa

| Capa | Qué hace |
|---|---|
| **UFW** | Solo deja entrar 22, 80 y 53. El 8181 de Pi-hole está bloqueado desde afuera y solo se llega vía Caddy |
| **fail2ban** | Banea por una hora tras 5 intentos fallidos, en SSH y en la autenticación de Caddy |
| **Caddy** | Punto único de entrada HTTP, con autenticación donde hace falta |
| **Tailscale** | Acceso remoto sin abrir un solo puerto en el router |

Nada de esto está publicado a internet. El router no tiene puertos abiertos hacia el Pi.

---

## Dónde viven los datos

Hay tres lugares distintos y conviene no confundirlos:

**Volúmenes de Docker.** Grafana, Prometheus, Wallabag, FreshRSS, Caddy y los servicios multimedia guardan acá su estado. Sobreviven a que recrees el contenedor. Se listan con `docker volume ls`.

**Carpetas del repositorio.** Las bases SQLite de fitbit, finanzas y news-filter viven en `data/` o `exports/` dentro de cada carpeta de servicio. Están en `.gitignore`, así que **no se van a GitHub**: si perdés el Pi, se pierden salvo que las tengas respaldadas aparte.

**El DAS.** Todo el contenido multimedia. Ver [../media/DAS.md](../media/DAS.md).

Los archivos `.env` con contraseñas y tokens también están fuera de git. Es lo correcto, pero implica que **son lo primero que hay que respaldar**.

---

## Lo que no es Docker

Dos piezas corren directamente en el sistema, no en contenedores, y en los dos casos es a propósito:

**Pi-hole**, porque tiene que responder DNS en el puerto 53 del host de forma confiable, incluso si Docker no está andando.

**Tailscale**, por la misma razón llevada al extremo: si Docker se rompe, querés poder entrar a arreglarlo. Un Tailscale contenerizado se caería junto con el problema que venís a resolver.

**Calibre** también es nativo, gestionado con servicios de usuario de systemd. Ver [../calibre/README.md](../calibre/README.md).

---

## Tareas programadas

En vez de que cada servicio traiga su propio programador, hay uno solo: **Ofelia**, que dispara trabajos en los demás contenedores según etiquetas. Un único lugar donde ver y cambiar todo lo que corre periódicamente. Ver [../ofelia/README.md](../ofelia/README.md).
