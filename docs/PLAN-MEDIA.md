# Plan de implementación del stack multimedia

Estado, decisiones tomadas, y el orden en que hay que hacer las cosas.

---

## Estado actual

| Pieza | Estado |
|---|---|
| `media/docker-compose.yml` | **Escrito.** 5 servicios, integrado al compose raíz |
| Entradas en Caddy | **Hechas.** `jellyfin.pi`, `radarr.pi`, `prowlarr.pi`, `bazarr.pi`, `qbit.pi` |
| `media/.env` | **Creado** con tus valores reales |
| Documentación | **Hecha.** [README](../media/README.md), [DAS](../media/DAS.md), [plugins](../media/JELLYFIN-PLUGINS.md) |
| Registros DNS en Pi-hole | **Pendiente**, son 5 |
| Grupo `render` | **Pendiente.** No existe en el sistema |
| DAS físico | **Pendiente**, todavía no lo tenés |
| Tailscale | **Pendiente** |

Los contenedores ya levantan con `docker compose up -d`, pero apuntan a un `/mnt/das` provisorio que es una carpeta en la SD, no el disco real.

---

## Decisiones cerradas

| Decisión | Elegido | Por qué |
|---|---|---|
| VPN para torrents | **No**, tráfico directo | Menos partes móviles. Tu IP queda visible para los pares |
| Almacenamiento | **Dos discos unidos con mergerfs** | Una sola biblioteca, hardlinks funcionando, y podés sumar un tercer disco después |
| Redundancia | **Ninguna** | Con dos discos no hay paridad sin resignar capacidad |
| Acceso remoto | **Tailscale** | Sin abrir puertos en el router |
| Series (Sonarr) | **No incluido** | No lo pediste. Entra igual el día que quieras |
| Cómo se levanta | **Junto con todo** | Un `docker compose up -d` levanta los 20 servicios |

---

## Fase 0: ahora, sin el DAS

Estas tres cosas no dependen del disco y conviene hacerlas ya.

### Registros DNS en Pi-hole

En `Local DNS → DNS Records`, cinco entradas apuntando a `192.168.68.66`:

```
jellyfin.pi    prowlarr.pi    radarr.pi    bazarr.pi    qbit.pi
```

Sin esto los nombres no resuelven y vas a ver un error de DNS, no de Caddy.

### Grupo render

Verifiqué que en tu Pi **no existe el grupo `render`**, y por eso `/dev/dri/renderD128` quedó como `root:root`. Sin arreglarlo, Jellyfin no puede usar el decodificador por hardware.

```bash
getent group render || sudo groupadd -r render
```

```bash
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=drm
```

Comprobá con `ls -la /dev/dri/renderD128`: tiene que decir `root render`.

### Tailscale

Seguí [../TAILSCALE.md](../TAILSCALE.md). Hacelo antes que el resto por una razón práctica: te da acceso remoto de emergencia independiente de Docker. El día que Docker se rompa, vas a querer tenerlo.

---

## Fase 1: cuando llegue el DAS

Seguí [../media/DAS.md](../media/DAS.md) completo. El resumen:

1. Formatear los dos discos en **ext4**, nunca NTFS ni exFAT
2. Instalar mergerfs y montar por UUID en `/etc/fstab`
3. Crear la estructura a través del conjunto, no en cada disco
4. **Correr la prueba de hardlinks de ese documento**

Ese último paso no es opcional. Si los hardlinks no funcionan, el stack duplica el espacio de cada película en silencio y te vas a enterar cuando el disco esté lleno.

Antes de montar el DAS real, borrá la carpeta provisoria:

```bash
sudo rm -rf /mnt/das/downloads /mnt/das/media /mnt/das/LEEME-NO-ES-EL-DAS.txt
```

Si no la borrás, esos archivos quedan **escondidos debajo** del montaje: siguen ocupando lugar en la SD y no los ves.

---

## Fase 2: configuración

El orden importa porque cada pieza se registra contra la anterior. Está detallado en [../media/README.md](../media/README.md).

```
qBittorrent  →  Prowlarr  →  Radarr  →  Bazarr  →  Jellyfin
```

Dos ajustes que son fáciles de pasar por alto y caros de descubrir tarde:

- En Radarr, **`Use Hardlinks instead of Copy`** activado.
- En Radarr, carpeta raíz `/data/media/movies`, y en qBittorrent las descargas en `/data/downloads`. **Los dos bajo `/data`**, que es el mismo montaje. Si apuntás a rutas distintas, se rompen los hardlinks.

---

## Fase 3: plugins de Jellyfin

Está en [../media/JELLYFIN-PLUGINS.md](../media/JELLYFIN-PLUGINS.md), con el detalle de qué es cada cosa. Tres aclaraciones que ahorran tiempo:

- **Trickplay ya es nativo** desde Jellyfin 10.9. No lo busques como plugin.
- **jellyfin_ratings no es un plugin**: es un userscript que necesita un inyector de JavaScript y una API key de mdblist.com.
- **jellyfin-rewind y jellyfin-watch-updater son aplicaciones externas**, no plugins. El segundo encaja como tarea de Ofelia.

El orden sugerido deja para el final lo más frágil ante actualizaciones, así si algo se rompe sabés que fue lo último que tocaste.

---

## Riesgos anotados

**El `/mnt/das` provisorio está en la SD.** No configures descargas hasta tener el disco real montado, o vas a llenar la tarjeta.

**Sin redundancia.** Si un disco muere, perdés lo que tenía. El otro queda legible, que ya es mejor que un RAID0, pero no es un backup.

**El Pi 5 no tiene codificador de video por hardware.** Decodifica bien, pero al transcodificar usa CPU. Apuntá a reproducción en formato nativo.
