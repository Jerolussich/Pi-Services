# Media

Stack multimedia del Pi. Descarga, organiza, subtitula y reproduce, con todo el contenido viviendo en un DAS de dos discos unidos.

---

## Arquitectura

```
                          ┌──────────────┐
                          │    Seerr     │  vos pedis aca
                          └──────┬───────┘
                                 │ lo manda al que corresponde
                    ┌────────────┴────────────┐
                    ▼                         ▼
                    ┌──────────┐   ┌──────────┐
   Prowlarr ───────▶│  Radarr  │   │  Sonarr  │◀─────── Prowlarr
  (indexers)        │peliculas │   │  series  │        (los mismos)
                    └────┬─────┘   └─────┬────┘
                         │  envian el torrent │
                         └─────────┬─────────-┘
                                   ▼
                          ┌──────────────┐
                          │ qBittorrent  │  baja a /data/downloads
                          └──────┬───────┘
                                 │ hardlink, no copia
                    ┌────────────┴────────────┐
                    ▼                         ▼
           /data/media/movies         /data/media/tv
                    │                         │
                    └────────────┬────────────┘
                                 │
   Bazarr  ─────────────────────▶│  les engancha subtitulos
  (subtitulos)                   │
                                 ▼  solo lectura
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

**Radarr y Sonarr son el mismo motor con distinto contenido.** Misma API, mismos endpoints, misma forma de configurarse. Cambian la carpeta y poco más: Sonarr además entiende de temporadas, episodios y calendario de emisión, que es lo que justifica que sean dos y no uno.

Comparten indexers (los de Prowlarr), cliente de descargas (qBittorrent) y subtitulador (Bazarr). Lo único que no comparten es la carpeta de destino, y eso es lo que le permite a Jellyfin tener dos bibliotecas distintas.

Dos cosas sostienen todo el diseño:

**Una única raíz de almacenamiento.** Los seis contenedores montan el DAS en el mismo path `/data`. Eso permite que Radarr importe con **hardlinks** en vez de copiar, así una película ocupa espacio una sola vez aunque figure en descargas y en la biblioteca.

**Los dos discos se ven como uno.** `mergerfs` los une en `/mnt/das`, así Jellyfin escanea una sola biblioteca y no te importa en qué disco cayó cada archivo. Está todo en [DAS.md](DAS.md).

---

## Servicios

| Contenedor | Imagen | Puerto interno | Hostname | Descripción |
|---|---|---|---|---|
| `jellyfin` | `jellyfin/jellyfin` | `8096` | `jellyfin.pi` | Servidor multimedia y reproducción |
| `seerr` | `ghcr.io/seerr-team/seerr` | `5055` | `seerr.pi` | Pedir contenido: buscás y apretás un botón |
| `radarr` | `lscr.io/linuxserver/radarr` | `7878` | `radarr.pi` | Gestión y automatización de películas |
| `sonarr` | `lscr.io/linuxserver/sonarr` | `8989` | `sonarr.pi` | Lo mismo para series, con temporadas y calendario |
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

```bash
cd ~/pi-services && docker compose up -d
```

Sube junto con el resto del stack, con el mismo comando que todo lo demás.

**Ojo con esto:** el stack multimedia arranca aunque el DAS no esté montado. `DAS_ROOT` apunta a `/mnt/das`, y esa carpeta existe igual, así que los contenedores levantan, se ven sanos, y descargan a la tarjeta del sistema hasta llenarla.

Quien te protege de eso es el instalador, que comprueba si `/mnt/das` está en otro dispositivo que la raíz del sistema y, si no lo está, te ofrece configurar todo con las descargas en pausa. Si levantás a mano, esa comprobación no corre y quedás por tu cuenta.

---

## Configuración inicial

**Esto lo hace el instalador.** Corré `./instalador.sh`, elegí el módulo de multimedia, y deja los seis servicios configurados y hablando entre ellos. Lo que sigue está para que sepas qué quedó hecho, y para hacerlo a mano si alguna vez lo necesitás.

El orden importa, porque cada pieza se registra contra la anterior.

### 1. qBittorrent

La contraseña temporal se imprime en el log del primer arranque:

```bash
docker logs qbittorrent | grep -i password
```

Entrá a `http://qbit.pi`, cambiala, y configurá las rutas como `/data/downloads/incomplete` y `/data/downloads/complete`.

Dos cosas que hacen tropezar acá. La primera es que **viene apuntando a `/downloads`, que en este stack no existe**: el DAS se monta en `/data` en los seis contenedores, así que sin corregirlo las descargas caen adentro del contenedor y se pierde el hardlink con la biblioteca. La segunda es que **no acepta contraseñas de menos de 6 caracteres**, y si la mandás por su API el error viene en el cuerpo de la respuesta, no en el código.

### 2. Prowlarr

En `http://prowlarr.pi`, agregá tus indexers. Después, en `Settings → Apps`, agregá Radarr con URL `http://radarr:7878` y Sonarr con `http://sonarr:8989`. Prowlarr les sincroniza los indexers solo, y no vas a tener que cargarlos de nuevo en cada aplicación.

Es el único lugar donde se cargan indexers. Ese es el punto de tener Prowlarr.

### 3. Radarr y Sonarr

Los dos igual, cambiando solo la carpeta:

| | Radarr | Sonarr |
|---|---|---|
| URL | `http://radarr.pi` | `http://sonarr.pi` |
| Carpeta raíz | `/data/media/movies` | `/data/media/tv` |

En los dos, `Settings → Media Management` para la carpeta raíz y para activar **`Use Hardlinks instead of Copy`**, y `Settings → Download Clients` para agregar qBittorrent con host `qbittorrent` y puerto `8080`.

**Validan la conexión al guardar**: si la contraseña de qBittorrent no es la correcta, no guardan nada y responden `Unable to connect to qBittorrent`.

Y no hace falta cargar los indexers acá: Prowlarr se los sincroniza a los dos.

### 4. Bazarr

En `http://bazarr.pi`, conectá Radarr con host `radarr` y puerto `7878`, y Sonarr con host `sonarr` y puerto `8989`.

El **perfil de idiomas** lo deja creado el instalador con Español e Inglés, y es más importante de lo que suena: sin uno, Bazarr corre, se ve sano, aparece conectado a Radarr y a Sonarr, y no baja un solo subtítulo nunca. Es el paso que más se olvida de todo el stack y el que peor avisa. Si querés otros idiomas, se cambia en `Settings → Languages`.

Lo que sí queda para vos es **de dónde bajarlos**, en `Settings → Providers`. Los que andan bien sin pagar son OpenSubtitles.com, que pide crear cuenta propia, y Subdivx. Si no elegís ninguno, Bazarr corre pero nunca baja nada.

Un detalle por si lo hacés a mano: los perfiles **no se guardan por su propio endpoint**, que contesta `405`. Van por el de configuración general, con el perfil serializado adentro:

```bash
curl -X POST -H "X-API-KEY: $KEY" --data-urlencode "languages-profiles=$PERFIL" http://bazarr:6767/api/system/settings
```

### 5. Jellyfin

En `http://jellyfin.pi`, creá dos bibliotecas: una de **Películas** apuntando a `/media/movies` y otra de **Series** apuntando a `/media/tv`. Es importante que sean dos y con el tipo correcto, porque Jellyfin busca los metadatos de forma distinta para cada una. En `Dashboard → Playback`, activá aceleración por hardware con **VAAPI** y dispositivo `/dev/dri/renderD128`.

Una advertencia concreta sobre el Pi 5: **no tiene codificador de video por hardware**. Decodifica H.264 y HEVC por hardware, pero al codificar usa CPU. Por eso hay que dejar la codificación por hardware **apagada**: si la activás, cada transcodificación falla. En la práctica conviene reproducir en formato nativo y evitar transcodificar. Si tus clientes soportan el códec original, el Pi 5 alcanza de sobra.

### 6. Seerr

En `http://seerr.pi`, entrás con tu usuario de Jellyfin, habilitás las bibliotecas, y conectás Radarr y Sonarr. El instalador lo deja hecho entero.

**Va último a propósito.** Seerr no hace nada por sí mismo: para configurarse necesita que Jellyfin ya tenga sus bibliotecas y que Radarr y Sonarr ya existan con su carpeta raíz. Si lo configurás antes, guarda conexiones vacías.

Hay una parte de esto que **no es idempotente**, y conviene saberlo: el primer POST a `/api/v1/auth/jellyfin` crea el usuario dueño y no se puede repetir. Por eso el instalador comprueba antes si ya hay usuarios, y si los hay no lo toca.

### El perfil de calidad que mejora solo

Radarr y Sonarr quedan con un perfil llamado **Perfeccionista**, que es el que usan los pedidos de Seerr.

Hace dos cosas. La primera es **aceptar todas las calidades**, así una película rara que solo existe en 480p igual se baja en vez de no bajarse nunca. La segunda es **poner el corte arriba de todo** con la mejora automática activada: cuando el indexer encuentra una versión mejor de algo que ya tenés, la baja y reemplaza la anterior sola.

O sea que pedís una vez y la copia va mejorando con el tiempo, sin que vuelvas a mirarla.

Quedan afuera dos calidades a propósito: **BR-DISK** y **Raw-HD**, que son la imagen del disco entera sin comprimir. Pesan decenas de gigas, muchos reproductores no las abren, y en un Pi 5 obligan a transcodificar, que es justo lo que conviene evitar.

| | Radarr | Sonarr |
|---|---|---|
| Calidades aceptadas | 24 de 26 | 17 de 18 |
| Corte | Remux-2160p | Bluray-2160p Remux |
| Mejora automática | sí | sí |

**Ojo con el espacio.** Este perfil pide lo mejor que exista, y lo mejor que existe pesa: un remux 2160p son entre 40 y 80 GB. Con la mejora automática además baja de nuevo lo que ya tenías. Si estás corto de disco, en `Settings → Profiles` bajá el corte a `Bluray-1080p` y la cosa se vuelve mucho más razonable.

### Contraseñas

Los cuatro `*arr` salen de fábrica **sin contraseña ninguna**, con `authenticationMethod: none`. Y Caddy tampoco les pone la suya, porque se asume que traen login propio. O sea que hasta que les pongas una, `radarr.pi`, `sonarr.pi`, `prowlarr.pi` y `bazarr.pi` están abiertos a cualquiera en tu red. El instalador se las configura; si lo hacés a mano, es en `Settings → General → Security`.

Seerr es la excepción: no tiene contraseña propia porque **entra con la de Jellyfin**. Un usuario menos que recordar, y si algún día cambiás la de Jellyfin, Seerr la sigue sin que hagas nada.

---

## Acceso desde afuera

Va por **Tailscale**, sin abrir puertos en el router. Para que funcione hacen falta dos cosas de [TAILSCALE.md](../TAILSCALE.md):

1. La ruta de la LAN aprobada en la consola de Tailscale.
2. El Pi puesto como **nameserver global** en esa misma consola.

Con eso, `http://jellyfin.pi` resuelve y es alcanzable desde tu celular en la calle, igual que en casa. Es la misma URL en los dos lados, que simplifica la configuración de los clientes.

Si alguna app de TV no resuelve los nombres `.pi`, la alternativa es publicar el puerto `8096` de Jellyfin y usar el nombre MagicDNS del Pi.

---

## Uso diario

**Lo normal es no abrir Radarr ni Sonarr nunca.** Entrás a `http://seerr.pi`, buscás lo que querés, apretás el botón, y listo. Seerr se da cuenta solo de si es película o serie y se lo manda al que corresponde. Además te muestra lo que ya tenés en Jellyfin, así no pedís dos veces lo mismo.

Por dentro pasa esto: el que recibe el pedido le pregunta a Prowlarr dónde encontrarlo, manda la descarga a qBittorrent, y al terminar la importa por hardlink a su carpeta, `movies` o `tv`. Bazarr le engancha los subtítulos y Jellyfin la muestra.

Con las series hay una diferencia que conviene saber: Sonarr sigue emitiendo. Una vez que agregás una serie en curso, se queda esperando los episodios nuevos y los baja al salir, sin que le pidas nada.

---

## Bajar y levantar todo

Los siete de una, sin tocar el resto del Pi:

```bash
cd ~/pi-services && docker compose stop jellyfin seerr qbittorrent prowlarr radarr sonarr bazarr
```

```bash
cd ~/pi-services && docker compose up -d jellyfin seerr qbittorrent prowlarr radarr sonarr bazarr
```

Los datos viven en volúmenes nombrados y en el DAS, así que bajarlos no borra nada. Para borrar también la configuración hay que agregar `-v` a un `down` explícitamente, y eso te deja empezando de cero.

---

## Notas

**El tráfico de torrents sale directo**, sin VPN. Tu IP es visible para los otros pares del enjambre. Si más adelante querés cambiarlo, el patrón habitual es un contenedor `gluetun` con killswitch y qBittorrent usando su red.

**El DAS no es un backup.** Son dos discos sin redundancia: si uno muere, se pierde lo que tenía. El otro queda intacto y legible, que ya es mejor que un RAID0, pero lo que no sea reemplazable guardalo en otro lado.
