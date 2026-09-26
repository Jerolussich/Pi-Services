# DAS: dos discos como uno solo

Tenés dos discos sin RAID y querés que se vean como un único espacio, que Jellyfin escanee todo junto y que cualquiera de los dos pueda tener películas. La herramienta para eso es **mergerfs**.

> **El instalador ya hace todo esto.** Cuando detecta que el DAS no está usable y hay un disco conectado sin usar, ofrece la opción `4) preparar ahora el disco que está conectado`, que ejecuta los pasos de abajo: formatea si hace falta, monta por UUID, arma el conjunto y prueba los hardlinks. Antes de borrar nada explica qué implica y pide que escribas `FORMATEAR`.
>
> Esta página queda como referencia de **qué** hace y **por qué**, y para el caso en que prefieras hacerlo a mano. La implementación vive en [`lib/discos.sh`](../lib/discos.sh).

---

## Qué hace mergerfs

Toma varios discos y los presenta como un solo punto de montaje. No mueve datos, no arma bloques ni paridad: cada archivo sigue viviendo entero en un disco concreto, y mergerfs decide en cuál escribir cada archivo nuevo.

```
/mnt/disk1  ──┐
              ├──▶  /mnt/das   (lo que ven los contenedores)
/mnt/disk2  ──┘
```

Tres consecuencias que conviene entender antes de empezar:

**No hay redundancia.** Si un disco muere, perdés lo que había en ese disco. El otro sigue intacto y legible, que es una ventaja real sobre RAID0, pero no es un backup.

**Podés agregar un tercer disco después** sin rehacer nada: se suma al conjunto y listo.

**Los hardlinks siguen funcionando**, que es la razón por la que este esquema sirve para el stack multimedia. Cuando Radarr crea un enlace, mergerfs lo crea en el mismo disco donde ya está el archivo original. Por eso importa que descargas y biblioteca estén **dentro del mismo montaje** `/mnt/das`, y no en dos montajes distintos.

---

## Instalación

```bash
sudo apt install mergerfs
```

---

## Preparación de los discos

Formateá **los dos** en ext4. Evitá NTFS y exFAT: no soportan hardlinks ni permisos POSIX, y sin hardlinks cada película ocuparía el doble.

```bash
sudo mkfs.ext4 -m 1 -T largefile -L disk1 /dev/sdX1
```

`-T largefile` reserva un inodo por MB en vez de uno cada 16 KB. El default asume archivos chicos: en 4 TB crea 244 millones de inodos que ocupan **62 GB** de tablas, para un disco que va a tener unos pocos miles de películas. Con esto quedan 3,8 millones, de sobra contando subtítulos, carátulas y `.nfo`, y el `fsck` tarda muchísimo menos después de un corte de luz.

`-m 1` en lugar del 5% por defecto libera 160 GB en un disco de 4 TB. No se baja a 0 a propósito: ese 1% le da a ext4 lugar para asignar bloques contiguos cuando el disco se acerca al límite, y la fragmentación es justo lo que arruina la lectura secuencial de un video.

```bash
lsblk -f
```

Anotá el `UUID` de cada uno. Creá los puntos de montaje individuales y el conjunto:

```bash
sudo mkdir -p /mnt/disk1 /mnt/disk2 /mnt/das
sudo chattr +i /mnt/disk1 /mnt/disk2 /mnt/das
```

Ese `chattr +i` no es opcional y es la protección más importante de toda esta página. Un punto de montaje vacío es una trampa: `/mnt/disk2` sin el disco montado es una carpeta común **en la tarjeta del sistema**, y mergerfs —que toma las ramas por el glob `/mnt/disk*`— la tomaría como un disco más con terabytes libres. Con `category.create=mfs` las descargas irían derecho a la tarjeta hasta llenarla, que es exactamente la falla que corrompe el sistema.

Con el flag de inmutable, escribir ahí falla mientras no haya nada montado encima. Montar sobre un directorio inmutable funciona igual, y una vez montado el flag queda debajo sin molestar.

---

## Montaje permanente

En `/etc/fstab`, primero los discos reales y después el conjunto:

```
UUID=uuid-del-disco-1  /mnt/disk1  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10  0  2
UUID=uuid-del-disco-2  /mnt/disk2  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10  0  2

/mnt/disk*  /mnt/das  fuse.mergerfs  defaults,allow_other,use_ino,cache.files=auto-full,dropcacheonclose=false,category.create=mfs,moveonenospc=true,minfreespace=20G,fsname=das,x-systemd.requires=/mnt/disk1,x-systemd.requires=/mnt/disk2  0  0
```

Qué hace cada opción que importa:

- `noatime` en los discos reales: sin esto cada **lectura** dispara una escritura de metadatos para anotar cuándo se leyó. Jellyfin escaneando la biblioteca y qBittorrent leyendo piezas para sembrar hacen miles de lecturas, y nada del stack usa el `atime`.
- `cache.files=auto-full` con `dropcacheonclose=false` es la decisión de velocidad más importante. Con `partial` la página cacheada se tira al cerrar el archivo, así que adelantar un video o volver a abrirlo vuelve a pegarle al disco. Con `auto-full` el contenido queda en el page cache del kernel y el seek es inmediato. Cuesta RAM, pero es caché reclamable: el kernel la suelta sola cuando algo la necesita.
- `use_ino` hace que los archivos reporten el mismo inodo que en el disco real. **Sin esto los hardlinks no se detectan bien** y Radarr terminaría copiando en vez de enlazar.
- `category.create=mfs` escribe cada archivo nuevo en el disco con **más espacio libre**, así se reparten solos sin que tengas que decidir nada.
- `moveonenospc=true`: si un disco se llena a mitad de una escritura, mueve el archivo al otro en vez de fallar.
- `minfreespace=20G` deja un margen para que ningún disco quede al borde.
- `nofail` en los discos reales: si un disco no está conectado, el Pi arranca igual. Después de lo que pasó con la corrupción, no querés que un disco flojo te deje sin arranque.
- `x-systemd.requires` asegura que el conjunto se monte después de los discos, no antes.

Aplicá y verificá:

```bash
sudo systemctl daemon-reload && sudo mount -a
```

```bash
df -h /mnt/das /mnt/disk1 /mnt/disk2
```

El tamaño de `/mnt/das` tiene que ser aproximadamente la suma de los dos.

---

## Estructura

Creala **una sola vez, a través del conjunto**, no en cada disco por separado:

```bash
sudo mkdir -p /mnt/das/downloads/{complete,incomplete} /mnt/das/media/{movies,tv}
sudo chown -R $(id -u):$(id -g) /mnt/das
```

Queda así:

```
/mnt/das/                    ← conjunto de los dos discos
├── downloads/
│   ├── complete/
│   └── incomplete/
└── media/
    ├── movies/          ← Radarr importa aca
    └── tv/              ← Sonarr importa aca
```

Las dos carpetas de `media` tienen que estar **bajo el mismo montaje que `downloads`**. Es lo que permite el hardlink: si estuvieran en discos distintos, importar copiaría en vez de enlazar y cada archivo ocuparía el doble.

Los contenedores montan `/mnt/das` completo como `/data`, y nunca ven los discos individuales. Para ellos es un solo volumen.

---

## Verificar que los hardlinks funcionan

Esta prueba vale la pena antes de cargar nada, porque si falla el stack entero duplica espacio en silencio:

```bash
cd /mnt/das && echo test > a && ln a b && stat -c "%h %i" a b && rm a b
```

Tiene que imprimir dos líneas iguales, con el contador de enlaces en `2` y el mismo número de inodo. Si el inodo difiere, falta `use_ino` en las opciones de montaje.

---

## Dónde quedó cada cosa

mergerfs no esconde los discos reales. Para ver qué archivo está en cuál:

```bash
ls /mnt/disk1/media/movies
```

```bash
ls /mnt/disk2/media/movies
```

Eso es útil justamente el día que falle un disco: sabés exactamente qué perdiste y qué no.

---

## Sobre la falta de redundancia

Con dos discos no hay forma de tener paridad sin resignar capacidad. Si más adelante sumás un tercero, **SnapRAID** encaja bien con mergerfs: usa un disco entero como paridad y te deja recuperar el contenido de cualquiera de los otros. Mientras tanto, asumí que el contenido del DAS es reemplazable, y guardá aparte lo que no lo sea.

---

## Qué hace el instalador según lo que encuentra

La preparación del disco es lo único del instalador que puede borrar datos, así que ramifica según el estado real de cada disco en vez de asumir nada. Lo que decide está en `disco_estado()`.

| Estado del disco | Qué encuentra | Qué hace |
|---|---|---|
| **listo** | ext4, xfs o btrfs | Lo monta tal cual. **No formatea**: los datos quedan intactos |
| **ajeno** | NTFS, exFAT, FAT | Explica que no sirve para hardlinks y ofrece formatear o dejarlo |
| **vacío** | sin ningún filesystem | Ofrece formatear, explicando qué implica |
| **en uso** | ya montado o en el fstab | Ni lo ofrece: lo lista como ocupado |

Dos reglas que no se negocian:

**Nunca formatea sin que escribas la palabra completa.** No es un `[S/n]`: hay que tipear `FORMATEAR`. Un dedo apoyado de más no puede costar cuatro terabytes.

**Un disco con filesystem se monta, no se formatea.** Que el instalador no sepa qué hay adentro no lo vuelve vacío.

## Correrlo de nuevo

Es seguro, y está pensado para eso. En una segunda corrida:

- El disco que ya está trabajando aparece como **en uso**, no como candidato. No hay forma de elegirlo por error.
- Si el DAS ya funciona y no hay discos libres, dice que está todo listo y no toca nada.
- Las líneas del `fstab` **no se duplican**: el disco se busca por UUID antes de agregarlo.
- El `chown -R` sobre la estructura corre **una sola vez**, al crearla. Con la biblioteca cargada, recorrer cientos de miles de archivos tardaría una eternidad y pisaría los dueños que los propios contenedores le pusieron a lo suyo.
- La línea del conjunto se reescribe **solo si cambió**. Si ya es la correcta y está montada, no se remonta: hacerlo con los contenedores arriba los deja mirando un montaje viejo hasta reiniciarlos. Cuando sí hace falta remontar, avisa y deja el pendiente anotado.

## Sumar un disco más adelante

No hay que formatear ni desmontar el disco que ya tenés. Conectás el nuevo, corrés el instalador y elegís la opción de preparar disco:

1. El disco nuevo se formatea y se monta en el primer `/mnt/diskN` libre.
2. La línea del conjunto se regenera con las dependencias de **todos** los discos.
3. `/mnt/das` pasa a ser la suma de los dos, y `DAS_ROOT` no cambia.

Los contenedores siguen viendo el mismo `/mnt/das` y nunca se enteran de que abajo hay dos discos. A partir de ahí `category.create=mfs` escribe cada archivo nuevo en el que tenga más espacio libre, así que se balancean solos.
