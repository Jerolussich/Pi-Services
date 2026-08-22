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

**El cron de Ofelia lleva seis campos y el primero son segundos.** No es el cron de siempre. Con los cinco clásicos, `0 * * * *` no significa "cada hora" sino "cada minuto", y nadie avisa: las tareas simplemente corren sesenta veces más de lo que pensabas. Para cada hora va `0 0 * * * *`.

---

## Cómo se mantiene solo

Cada dato vive **en un solo lugar** y lo demás se deriva de ahí. Es lo que hace que agregar un servicio no sea un recorrido por seis archivos, acordándose de todos.

El costo de no hacerlo así no es el trabajo extra: es que el día que te olvidás de uno, el síntoma no se parece en nada a la causa. Un servicio sin registro DNS da un error de red. Un puerto desactualizado en una tabla hace que el diagnóstico reporte caído algo que está perfecto.

### Los nombres y los puertos salen del Caddyfile

El Caddyfile ya dice, en una línea, qué nombre atiende y contra qué puerto va:

```
http://sonarr.pi {
    import accesslog
    reverse_proxy sonarr:8989
}
```

De ahí se derivan dos cosas que antes estaban escritas a mano:

| Qué | Quién lo usa | Antes |
|---|---|---|
| Los registros DNS `*.pi` de Pi-hole | el instalador, al configurar Pi-hole | una lista fija de 15 nombres |
| El puerto interno de cada servicio | el diagnóstico, para preguntarle si responde | una tabla de 14 entradas |

Las funciones son `hosts_del_caddyfile` y `puerto_de`, las dos en [../lib/comun.sh](../lib/comun.sh).

**Consecuencia práctica:** agregar un servicio es agregar su bloque al Caddyfile. Los registros DNS se cargan solos la próxima vez que corras el instalador, incluso si Pi-hole ya estaba andando.

### El instalador y el diagnóstico comparten lo que saben

`instalador.sh` sabe **configurar** cada servicio. `diagnostico.sh` sabe **comprobarlo**. Son la misma pregunta desde dos lados, así que si cada uno tuviera su propia idea de qué significa "Radarr está bien", en tres meses dirían cosas distintas.

Por eso todo ese conocimiento vive en [../lib/comun.sh](../lib/comun.sh), que los dos cargan: las definiciones de módulos y servicios, las variables requeridas, la detección de estado y la configuración automática por API. Cada script se queda solo con su flujo.

### Los servicios parecidos comparten código, no copias

Radarr y Sonarr son el mismo motor con distinto contenido: misma API, mismos endpoints, misma forma de configurarse. Cambian el puerto, la carpeta, y cómo llama cada uno a su categoría de descargas.

Van por una sola función, `cfg_arr`, con esas tres cosas como parámetros:

```bash
cfg_radarr() { cfg_arr radarr 7878 Radarr /data/media/movies movie "$1"; }
cfg_sonarr() { cfg_arr sonarr 8989 Sonarr /data/media/tv     tv    "$1"; }
```

Con dos copias, cualquier arreglo hay que acordarse de hacerlo dos veces, y el día que te olvidás queda un bug que solo aparece en las series. El diagnóstico usa el mismo patrón con `rev_un_arr`.

### El nombre de proyecto está fijado

Los once compose empiezan con `name: pi-services`. Sin eso, Compose usa el nombre de la carpeta, y ese nombre prefija todos los volúmenes: levantar un módulo desde su carpeta, o clonar el repo con otro nombre, creaba un juego de volúmenes paralelo y todo aparecía vacío. Está explicado en [OPERACION.md](OPERACION.md).

### Qué sigue sin derivarse

Para ser honestos, no todo está resuelto. La lista de servicios por módulo (`SERVICIOS` en `lib/comun.sh`) sigue escrita a mano, y podría salir del `docker-compose.yml` de cada carpeta. Lo mismo la asociación servicio a módulo. Son los dos lugares que hay que tocar al agregar algo, además del Caddyfile.
