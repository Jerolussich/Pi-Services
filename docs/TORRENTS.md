# El puerto de torrents

qBittorrent es el único programa de este stack que habla con desconocidos, y por eso es el único con un puerto propio y el único que está encerrado a propósito. Este documento explica qué decisión tenés que tomar, qué cambia en cada caso, qué deja hecho el instalador pase lo que pase y qué riesgos quedan.

---

## La decisión: ¿abrir el puerto o no?

qBittorrent baja y sube datos conectándose con otras personas. Hay dos direcciones:

- **Las conexiones que iniciás vos** salen siempre, con el puerto abierto o cerrado. Descargar funciona igual.
- **Las conexiones que te inician a vos** solo llegan si el puerto 6881 es alcanzable desde internet. Eso es lo que "abrir el puerto" habilita.

### Qué ganás abriéndolo

- **Sembrar de verdad.** Con el puerto cerrado casi nadie puede alcanzarte, y subir datos casi no pasa.
- **Llegar a torrents con pocos seeds**, si la otra punta también está detrás de un router: dos extremos cerrados no pueden conectarse entre sí, y vos podrías ser el que da el primer paso.

### Qué *no* ganás

- No cambia la velocidad de los torrents populares: ahí sobran los seeds alcanzables.
- No ahorra espacio ni disco.
- El *ratio* solo importa en trackers privados. Acá se usan indexers públicos.

Dicho sin vueltas: **abrir el puerto ayuda sobre todo a los demás**. Para vos, el beneficio es marginal.

### Qué implica

- **Un programa queda expuesto a internet: qBittorrent.** Si tuviera una vulnerabilidad, esa sería la puerta de entrada. Y el firewall de esta máquina no filtra este puerto, porque Docker publica por su cuenta (ver [Lo que queda sin cubrir](#lo-que-queda-sin-cubrir)).
- **Tu IP no queda más expuesta.** El enjambre ya la ve cuando descargás; abrir el puerto no la hace más visible.
- Hay una pequeña superficie nueva y un beneficio chico. Por eso **el valor por defecto es cerrado**.

---

## Las tres opciones del instalador

El instalador lo explica en pantalla antes de preguntar. Si apretás Enter, queda **cerrado**.

| | Qué hace | Qué tenés que tocar |
|---|---|---|
| **1. Cerrado** (recomendado) | El puerto escucha solo en `127.0.0.1`. Ni la red local lo alcanza | Nada |
| **2. Abierto por UPnP** | Escucha en `0.0.0.0` y la mini PC le pide al router que lo reenvíe | Nada en el router |
| **3. Abierto, reenvío a mano** | Escucha en `0.0.0.0`; el reenvío lo creás vos en el router | La regla de *port forwarding* |

### Qué es UPnP, y qué implica

UPnP es un protocolo con el que un aparato de la red le pide al router "abrime este puerto hacia mí". El router crea la regla sin que nadie entre a su panel.

- **Ventaja:** no tocás el router.
- **Implicancia:** cualquier aparato de tu red puede pedirle lo mismo al router, no solo esta máquina. Una cámara, una tele o un programa infectado podrían abrir puertos hacia adentro sin que te enteres. Es la razón por la que muchos lo apagan.
- **Qué hace este repo:** pide solo el puerto 6881 (TCP y UDP), con una concesión de una hora, y un timer (`pi-upnp.timer`) la renueva cada media hora. Si cambiás a cerrado, el instalador borra la regla; si se apaga la mini PC, la regla vence sola a la hora.
- **Lo que UPnP no puede hacer:** no toca la configuración de esta máquina. Solo habla con el router.

### Si tu proveedor comparte la IP

Algunos proveedores le dan la misma IP pública a muchos clientes (CGNAT). En ese caso **ningún reenvío sirve**, ni a mano ni por UPnP: el router de tu proveedor no te lo pasa. El instalador lo detecta —la IP que reporta el router es privada o del rango compartido `100.64.0.0/10`— y deja el puerto cerrado en vez de fingir que funciona.

### Si no hay UPnP en el router

Si elegís la opción 2 y el router no contesta, el instalador no la da por buena: pasa a la opción 3, te muestra qué reenviar y deja un pendiente para que lo recuerdes.

---

## Lo que el instalador deja hecho, abras o no el puerto

El puerto es la mitad de la historia. La otra mitad es limitar el daño si algún día qBittorrent falla.

### 1. Una red de Docker aparte

qBittorrent vive en `pi-torrent`, **no** en `pi-services`, donde están los otros veinte contenedores. No puede ver a Jellyfin, a Home Assistant, a los exporters ni a nadie más por nombre ni por IP de red de contenedores.

Los que sí le hablan están en las dos redes: Radarr y Sonarr (le mandan descargas), y Caddy y la homepage (le muestran la interfaz). Esos contenedores siguen con su ruta de salida normal por `pi-services`.

```
pi-services  ── Caddy ── Jellyfin, Radarr, Sonarr, Prowlarr, Bazarr, ...
                 │            │
pi-torrent   ────┴────────────┴── qBittorrent   ← el único que habla con desconocidos
```

### 2. Permisos recortados

En [../media/docker-compose.yml](../media/docker-compose.yml):

- `no-new-privileges:true`: aunque algo adentro lo intente, no puede ganar privilegios nuevos.
- `cap_drop: ALL` y luego solo cinco capacidades de vuelta: `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`. Son las que necesita el arranque de la imagen de linuxserver para cambiar de usuario y ordenar permisos. Se verificó que con solo esas arranca y funciona.

Sin esto, un fallo en qBittorrent le daría al atacante todo lo que root puede hacer dentro del contenedor.

### 3. Una regla de firewall para que no llegue a esta máquina

Estar en otra red de Docker no alcanza para esto. Los contenedores salen por el *gateway* de su red, que es esta máquina, y UFW ya tiene reglas que permiten a las redes de Docker (`172.17.0.0/16` a `172.20.0.0/16`) llegar a Home Assistant (8123) y a Pi-hole (8181). La red nueva cae dentro de ese rango, así que **heredaba esos permisos**.

El instalador inserta, **en primer lugar** (UFW usa la primera regla que coincide), una negación para la subred de `pi-torrent`:

```
ufw insert 1 deny from <subred de pi-torrent> to any comment 'pi-torrent: qBittorrent sin acceso a este equipo'
```

Con eso qBittorrent no llega al SSH, a Home Assistant ni a Pi-hole de esta máquina. La subred se lee de Docker, no se fija a mano, y la regla se verifica leyéndola de vuelta.

### 4. El puerto se publica solo donde corresponde

`QBIT_ESCUCHA` en `media/.env` decide en qué interfaz escucha el puerto publicado:

| Valor | Quién lo alcanza |
|---|---|
| `127.0.0.1` (por defecto) | Solo esta máquina. Es "cerrado" |
| `0.0.0.0` | Cualquiera que llegue a la máquina; por internet, solo si además hay reenvío en el router |

La interfaz web de qBittorrent **nunca** se publica: va por Caddy en `http://qbit.pi`, como todo lo demás.

---

## Lo que queda sin cubrir

Esto es lo que este cambio **no** resuelve, para que no te quedes con una idea de más seguridad de la que hay:

- **qBittorrent todavía llega a los puertos que Docker publica en esta máquina**: Caddy (80 y 443), Seerr (5055) y Jellyfin (8096). Docker publica esos puertos salteándose UFW, así que la regla de arriba no los cubre. Cerrarlo del todo requiere reglas en la cadena `DOCKER-USER` de iptables y no está implementado.
- **Tampoco bloquea a los aparatos de tu red local.** Desde `pi-torrent` se sale a internet, y por esa misma salida se podría llegar a la tele, al router o a una cámara.
- **Contenedores con privilegios que no tocó este cambio.** Hay otros con acceso a `docker.sock` o con permisos ampliados; no son alcanzables desde qBittorrent por red, pero un atacante que ya estuviera adentro de alguno de ellos es otro problema.

El aislamiento convierte un compromiso total en uno mucho más acotado. No lo vuelve imposible.

---

## Cambiarlo después: `pi puerto`

Sin volver a correr el instalador entero:

```bash
pi puerto
```

Muestra el estado y, si querés, lo cambia:

```
Puerto de torrents  (6881)

  Esta máquina:   cerrado: ni la red local lo alcanza
  ✓ Desde internet: no se ve (es lo esperado)

  Aislamiento de qBittorrent:
  ✓ red aparte (pi-torrent)
  ✓ sin forma de ganar privilegios
  ✓ el firewall le bloquea el acceso a esta máquina
```

La comprobación "desde internet" se hace con un servicio externo (`ifconfig.co`), que intenta conectarse al puerto. Eso le manda tu IP pública y el número de puerto, algo que cualquiera con quien compartís un torrent ya ve. Tiene tres respuestas, no dos: *se ve*, *no se ve* y *no pude comprobarlo* (sin internet, o el servicio caído); la última no se reporta como falla. Solo prueba TCP.

### Qué revisa el diagnóstico

`./diagnostico.sh` (o `pi estado`) verifica, dentro del bloque de multimedia, que qBittorrent esté en su red, que no pueda ganar privilegios, que la regla de UFW exista y en qué estado está el puerto. Si falta el aislamiento ofrece repararlo con `./diagnostico.sh --arreglar` (`rep_aislar_torrents`).

---

## Volver a correr el instalador

- **La decisión se recuerda.** Queda en `media/.env` (`QBIT_ESCUCHA`, `QBIT_UPNP`, `QBIT_PUERTO_DECIDIDO`) y no se vuelve a preguntar. Para cambiarla: `pi puerto`.
- **Las redes se crean antes de levantar**, cada vez que se levanta un módulo, porque los composes declaran `pi-services` y `pi-torrent` como externas. Si faltara una, `docker compose up` falla sin levantar nada.
- **`pi actualizar` también las asegura**, para equipos instalados antes de que existiera `pi-torrent`.
- **La regla de UFW es idempotente**: si ya está, no la repite; si quedó una vieja de una subred anterior, la reemplaza.

---

## Variables

| Variable | Archivo | Valores | Qué hace |
|---|---|---|---|
| `QBIT_TORRENT_PORT` | `media/.env` | `6881` | El puerto |
| `QBIT_ESCUCHA` | `media/.env` | `127.0.0.1` / `0.0.0.0` | Quién puede alcanzar el puerto publicado |
| `QBIT_UPNP` | `media/.env` | `0` / `1` | Si el timer pide el puerto al router por UPnP |
| `QBIT_PUERTO_DECIDIDO` | `media/.env` | `1` | Marca que ya se eligió, para no volver a explicarlo |

## Archivos

- [../lib/torrents.sh](../lib/torrents.sh): la lógica completa: redes, firewall, UPnP, asistente y `pi puerto`
- [../systemd/pi-upnp.service](../systemd/pi-upnp.service) y [../systemd/pi-upnp.timer](../systemd/pi-upnp.timer): la renovación de la concesión de UPnP, activa solo si elegiste esa opción
- [../media/docker-compose.yml](../media/docker-compose.yml): la red, los permisos y el puerto

## Qué no está probado

El camino de **crear** la regla en el router por UPnP no se probó contra un router real: eso modifica el router, y no se hizo sin autorización. Sí se probó el resto: aislamiento de red, permisos, regla de UFW (incluida su idempotencia), `pi puerto` y el diagnóstico. Si elegís UPnP y algo falla, el instalador lo dice y deja el puerto como reenvío manual.
