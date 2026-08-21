# DAS: dos discos como uno solo

Tenés dos discos sin RAID y querés que se vean como un único espacio, que Jellyfin escanee todo junto y que cualquiera de los dos pueda tener películas. La herramienta para eso es **mergerfs**.

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
lsblk -f
```

Anotá el `UUID` de cada uno. Creá los puntos de montaje individuales y el conjunto:

```bash
sudo mkdir -p /mnt/disk1 /mnt/disk2 /mnt/das
```

---

## Montaje permanente

En `/etc/fstab`, primero los discos reales y después el conjunto:

```
UUID=uuid-del-disco-1  /mnt/disk1  ext4  defaults,nofail,x-systemd.device-timeout=10  0  2
UUID=uuid-del-disco-2  /mnt/disk2  ext4  defaults,nofail,x-systemd.device-timeout=10  0  2

/mnt/disk*  /mnt/das  fuse.mergerfs  defaults,nonempty,allow_other,use_ino,cache.files=partial,dropcacheonclose=true,category.create=mfs,moveonenospc=true,minfreespace=20G,fsname=das,x-systemd.requires=/mnt/disk1,x-systemd.requires=/mnt/disk2  0  0
```

Qué hace cada opción que importa:

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
sudo mkdir -p /mnt/das/downloads/{complete,incomplete} /mnt/das/media/movies
sudo chown -R $(id -u):$(id -g) /mnt/das
```

Queda así:

```
/mnt/das/                    ← conjunto de los dos discos
├── downloads/
│   ├── complete/
│   └── incomplete/
└── media/
    └── movies/
```

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
