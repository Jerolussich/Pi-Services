# Media

Stack multimedia del Pi. Descarga, organiza, subtitula y reproduce, con todo el contenido viviendo en un DAS de dos discos unidos.

---

## Arquitectura

```
                    ┌──────────────┐
   Prowlarr  ──────▶│    Radarr    │  busca y decide que bajar
  (indexers)        └──────┬───────┘
                           │ envia el torrent
                           ▼
                    ┌──────────────┐
                    │ qBittorrent  │  descarga a /data/downloads
                    └──────┬───────┘
                           │ hardlink (no copia) a /data/media
                           ▼
                    ┌──────────────┐
   Bazarr    ──────▶│  /data/media │  biblioteca final
  (subtitulos)      └──────┬───────┘
                           │ solo lectura
                           ▼
                    ┌──────────────┐
                    │   Jellyfin   │  reproduce
                    └──────┬───────┘
                           │
                    ┌──────┴───────┐
                    │  /mnt/das    │  mergerfs
                    └──┬────────┬──┘
                       │        │
                   /mnt/disk1  /mnt/disk2
```

Dos cosas sostienen todo el diseño:

**Una única raíz de almacenamiento.** Los cinco contenedores montan el DAS en el mismo path `/data`. Eso permite que Radarr importe con **hardlinks** en vez de copiar, así una película ocupa espacio una sola vez aunque figure en descargas y en la biblioteca.

**Los dos discos se ven como uno.** `mergerfs` los une en `/mnt/das`, así Jellyfin escanea una sola biblioteca y no te importa en qué disco cayó cada archivo. Está todo en [DAS.md](DAS.md).

---

## Servicios

| Contenedor | Imagen | Puerto interno | Hostname | Descripción |
|---|---|---|---|---|
| `jellyfin` | `jellyfin/jellyfin` | `8096` | `jellyfin.pi` | Servidor multimedia y reproducción |
| `radarr` | `lscr.io/linuxserver/radarr` | `7878` | `radarr.pi` | Gestión y automatización de películas |
| `prowlarr` | `lscr.io/linuxserver/prowlarr` | `9696` | `prowlarr.pi` | Gestor central de indexers |
| `bazarr` | `lscr.io/linuxserver/bazarr` | `6767` | `bazarr.pi` | Descarga automática de subtítulos |
| `qbittorrent` | `lscr.io/linuxserver/qbittorrent` | `8080` | `qbit.pi` | Cliente de descargas |

Ningún contenedor publica su interfaz web al host: todo entra por Caddy, igual que el resto del repo. La única excepción es el puerto de torrenting de qBittorrent, que necesita aceptar conexiones entrantes de otros pares.

---

## Estructura

```
media/
├── docker-compose.yml
├── .env                    ← gitignored
├── .env.example
├── README.md
├── DAS.md                  ← los dos discos con mergerfs
└── JELLYFIN-PLUGINS.md     ← plugins, cuáles son nativos y cuáles no
```

---

## Puesta en marcha

### 1. El DAS primero

Seguí [DAS.md](DAS.md) completo. No sigas hasta que la prueba de hardlinks de ese documento pase: si falla, el stack duplica espacio en silencio y te enterás tarde.

### 2. Aceleración por hardware

Verifiqué esto en tu Pi y hay algo que arreglar antes: **el grupo `render` no existe**, y por eso `/dev/dri/renderD128` quedó como `root:root`. Sin eso Jellyfin no puede usar el decodificador por hardware.

```bash
getent group render || sudo groupadd -r render
```

```bash
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=drm
```

Comprobá que cambió de dueño:

```bash
ls -la /dev/dri/renderD128
```

Tiene que decir `root render`. Si sigue en `root root`, un reinicio lo resuelve.

### 3. Configuración

```bash
cp .env.example .env
```

Completá con tus valores reales:

```bash
id -u; id -g                              # PUID y PGID
```

### 4. Levantar

El stack está bajo el profile `media`, así que no arranca con el `up` normal del repo. Es a propósito: sin el DAS montado los contenedores fallarían y te ensuciarían el arranque del resto del Pi.

```bash
docker compose --profile media up -d
```

---

## Configuración inicial

**Esto lo hace el instalador.** Corré `./instalador.sh`, elegí el módulo de multimedia, y deja los cinco servicios configurados y hablando entre ellos. Lo que sigue está para que sepas qué quedó hecho, y para hacerlo a mano si alguna vez lo necesitás.

El orden importa, porque cada pieza se registra contra la anterior.

### 1. qBittorrent

La contraseña temporal se imprime en el log del primer arranque:

```bash
docker logs qbittorrent | grep -i password
```

Entrá a `http://qbit.pi`, cambiala, y configurá las rutas como `/data/downloads/incomplete` y `/data/downloads/complete`.

Dos cosas que hacen tropezar acá. La primera es que **viene apuntando a `/downloads`, que en este stack no existe**: el DAS se monta en `/data` en los cinco contenedores, así que sin corregirlo las descargas caen adentro del contenedor y se pierde el hardlink con la biblioteca. La segunda es que **no acepta contraseñas de menos de 6 caracteres**, y si la mandás por su API el error viene en el cuerpo de la respuesta, no en el código.

### 2. Prowlarr

En `http://prowlarr.pi`, agregá tus indexers. Después, en `Settings → Apps`, agregá Radarr con URL `http://radarr:7878`. Prowlarr le sincroniza los indexers solo, y no vas a tener que cargarlos de nuevo en cada aplicación.

### 3. Radarr

En `http://radarr.pi`:

- `Settings → Media Management`: carpeta raíz `/data/media/movies`, y activá **`Use Hardlinks instead of Copy`**.
- `Settings → Download Clients`: qBittorrent, host `qbittorrent`, puerto `8080`.

Radarr **valida la conexión al guardar**: si la contraseña de qBittorrent no es la correcta, no guarda nada y responde `Unable to connect to qBittorrent`.

### 4. Bazarr

En `http://bazarr.pi`, conectá Radarr con host `radarr` y puerto `7878`, y elegí proveedores e idiomas.

Sin un **perfil de idiomas** creado no baja ningún subtítulo, aunque tengas proveedores configurados. Es el paso que más se olvida.

### 5. Jellyfin

En `http://jellyfin.pi`, creá la biblioteca de películas apuntando a `/media/movies`. En `Dashboard → Playback`, activá aceleración por hardware con **VAAPI** y dispositivo `/dev/dri/renderD128`.

Una advertencia concreta sobre el Pi 5: **no tiene codificador de video por hardware**. Decodifica H.264 y HEVC por hardware, pero al codificar usa CPU. Por eso hay que dejar la codificación por hardware **apagada**: si la activás, cada transcodificación falla. En la práctica conviene reproducir en formato nativo y evitar transcodificar. Si tus clientes soportan el códec original, el Pi 5 alcanza de sobra.

### Contraseñas

Los tres `*arr` salen de fábrica **sin contraseña ninguna**, con `authenticationMethod: none`. Y Caddy tampoco les pone la suya, porque se asume que traen login propio. O sea que hasta que les pongas una, `radarr.pi`, `prowlarr.pi` y `bazarr.pi` están abiertos a cualquiera en tu red. El instalador se las configura; si lo hacés a mano, es en `Settings → General → Security`.

---

## Acceso desde afuera

Va por **Tailscale**, sin abrir puertos en el router. Para que funcione hacen falta dos cosas de [TAILSCALE.md](../TAILSCALE.md):

1. La ruta de la LAN aprobada en la consola de Tailscale.
2. El Pi puesto como **nameserver global** en esa misma consola.

Con eso, `http://jellyfin.pi` resuelve y es alcanzable desde tu celular en la calle, igual que en casa. Es la misma URL en los dos lados, que simplifica la configuración de los clientes.

Si alguna app de TV no resuelve los nombres `.pi`, la alternativa es publicar el puerto `8096` de Jellyfin y usar el nombre MagicDNS del Pi.

---

## Uso diario

Agregás una película en Radarr, que le pide a Prowlarr dónde encontrarla, manda la descarga a qBittorrent, y al terminar la importa por hardlink a la biblioteca. Bazarr le engancha los subtítulos y Jellyfin la muestra.

---

## Bajar y levantar todo

```bash
docker compose --profile media down
```

```bash
docker compose --profile media up -d
```

Los datos viven en volúmenes nombrados y en el DAS, así que `down` no borra nada. Para borrar también la configuración hay que agregar `-v` explícitamente, y eso te deja empezando de cero.

---

## Notas

**El tráfico de torrents sale directo**, sin VPN. Tu IP es visible para los otros pares del enjambre. Si más adelante querés cambiarlo, el patrón habitual es un contenedor `gluetun` con killswitch y qBittorrent usando su red.

**Sonarr no está incluido.** Si querés series, entra igual: mismo `/data`, carpeta raíz `/data/media/tv`, y se agrega a Prowlarr y Bazarr con el mismo patrón.

**El DAS no es un backup.** Son dos discos sin redundancia: si uno muere, se pierde lo que tenía. El otro queda intacto y legible, que ya es mejor que un RAID0, pero lo que no sea reemplazable guardalo en otro lado.
