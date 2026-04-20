# Calibre

Servidor de biblioteca personal de libros electrónicos. Corre **nativo en el Pi** (no en Docker), expone la biblioteca por web y actúa como distribuidor central para leer desde cualquier dispositivo (browser, e-reader con OPDS, Moon+ Reader, KOReader, etc.).

La gestión de libros (búsqueda, descarga de fuentes open-source, metadata) se hace con **Calibre Desktop en la laptop**. Los libros se suben al Pi por el **web UI** del Content Server — el server corre con `--enable-local-write` así que cualquier usuario autenticado (vía Caddy) puede agregar libros desde el browser.

---

## Arquitectura

```
calibre/
├── README.md
├── install.sh                           ← setup one-shot
├── bin/
│   ├── calibre-ingest                   ← procesa ~/calibre-inbox con dedup automático
│   └── calibre-wipe                     ← nuclear option: borrar TODA la biblioteca (con warnings)
└── systemd/
    ├── calibre-server.service           ← user-service con auto-restart
    ├── calibre-ingest.service           ← oneshot disparado por el timer
    └── calibre-ingest.timer             ← corre calibre-ingest cada minuto
```

**Dos piezas:**

- **`calibre-server`** (headless, systemd user-service en el Pi) — corre 24/7 en puerto `8083`. Sirve la biblioteca por web, OPDS, y acepta uploads de libros nuevos.
- **Calibre Desktop** (en tu laptop Windows/Mac/Linux) — donde buscás y descargás libros nuevos usando "Get Books". Mantiene su propia biblioteca local en la laptop. Los libros que querés en el Pi los subís uno a uno al web UI.

Ambos pueden convivir sin problema: cada uno tiene su biblioteca, el Pi es el "archivo canónico" al que subís lo que querés tener disponible desde otros dispositivos.

---

## Instalación en el Pi

### Opción A — script automático

Desde este directorio, corriendo como el usuario que va a usar Calibre (**no** como root):

```bash
./install.sh
```

El script hace todo: instala `calibre` desde apt, crea e inicializa la biblioteca en `~/calibre-library`, copia el user-service a `~/.config/systemd/user/`, lo habilita y activa linger.

### Opción B — pasos manuales

```bash
# 1. Instalar calibre
sudo apt update
sudo apt install -y calibre

# 2. Crear e inicializar biblioteca
mkdir -p ~/calibre-library
calibredb list --with-library ~/calibre-library   # crea metadata.db

# 3. Instalar user-service
mkdir -p ~/.config/systemd/user
cp systemd/calibre-server.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now calibre-server

# 4. Linger (arranca el service al boot aunque no haya login)
sudo loginctl enable-linger $USER
```

### Verificación

```bash
systemctl --user status calibre-server
curl -I http://localhost:8083
```

---

## Instalación de Calibre Desktop en tu laptop

Bajá el instalador oficial de https://calibre-ebook.com/download

- **Windows** — instalador `.msi`
- **macOS** — `.dmg`
- **Linux** — `sudo apt install calibre` o el binary release oficial

Primera corrida: Calibre te pide crear una biblioteca local. Dejá la default (normalmente `Documents\Calibre Library` en Windows). **Esta biblioteca vive en tu laptop, no en el Pi** — no hay que tocar nada del Pi.

---

## Uso

### Descubrir y descargar libros (en la laptop)

1. Abrí Calibre Desktop en la laptop
2. Tocá el botón **"Get Books"** (ícono del carrito arriba)
3. Buscá por autor/título. Por default busca en fuentes libres: Project Gutenberg, Internet Archive, Feedbooks, ManyBooks, Open Library, Smashwords, MobileRead, Standard Ebooks
4. Descargás el EPUB → queda en la biblioteca local de tu laptop

### Subir un libro al Pi (para tenerlo disponible desde otros dispositivos)

1. En el browser de la laptop, abrí `http://calibre.pi` y autenticate con las credenciales de Caddy (mismas que `homepage.pi`)
2. Arriba a la derecha → botón **"Add books"**
3. Pickeás el EPUB desde tu biblioteca local (ej. `Documents\Calibre Library\Author\Book\Book.epub`) y subís

El libro aparece en el Pi y queda accesible vía:
- `http://calibre.pi` desde cualquier browser
- OPDS `http://calibre.pi/opds` desde e-readers / apps móviles

**Tip**: no hace falta subir al Pi todos los libros que tenés. Subí solo los que querés leer desde múltiples dispositivos o archivar centralmente.

### Leer desde el celular/e-reader

Agregá el catálogo OPDS en tu app de lectura favorita (KOReader, Moon+ Reader, KyBook, FBReader):

```
http://calibre.pi/opds
```

---

## Fuentes open-source de libros

### Built-in "Get Books" (Calibre Desktop)

Al abrir "Get Books" en Calibre Desktop, ya tenés habilitadas por default:

- **Project Gutenberg** — clásicos en dominio público
- **Internet Archive / Open Library**
- **Feedbooks (Public Domain)**
- **ManyBooks**
- **Smashwords**
- **MobileRead**
- **Standard Ebooks**

En `Preferences → Get Books` podés activar/desactivar fuentes individuales y filtrar solo por las gratis.

### Plugins útiles para la Desktop

Instalá con `Preferences → Plugins → Get new plugins` (se instalan en la laptop, no en el Pi):

| Plugin | Para qué |
|---|---|
| **Count Pages** | Calcula páginas/palabras para metadata |
| **Goodreads Sync** | Importar/sync listas de Goodreads |
| **Search the Internet** | Buscar un libro en Google/Amazon/etc. con un clic |
| **EpubMerge / EpubSplit** | Manipular archivos EPUB |
| **Modify ePub** | Editar metadata del EPUB sin recompilar |
| **Quality Check** | Detecta problemas de formato en tu biblioteca |

### Feeds OPDS externos (complementan Calibre)

Para leer directamente desde tu e-reader sin pasar por tu biblioteca:

| Fuente | URL OPDS |
|---|---|
| Standard Ebooks | `https://standardebooks.org/opds` |
| Project Gutenberg | `https://m.gutenberg.org/ebooks.opds/` |
| Feedbooks Public Domain | `https://catalog.feedbooks.com/catalog/public_domain.atom` |
| Manybooks | `https://manybooks.net/opds/` |

---

## Borrar libros

### Un libro a la vez (web UI)

En `http://calibre.pi`:
1. Click en el libro para abrir sus detalles
2. Menu **"⋮"** arriba a la derecha → **"Delete book"**
3. Confirmás

### Varios libros a la vez (web UI)

1. Arriba del listado, icono de **checkbox/selección múltiple**
2. Marcás los libros que querés borrar
3. Menu → **"Delete books"**

### Nuclear option — borrar TODA la biblioteca

Para casos donde querés empezar de cero, hay un script `calibre-wipe` accesible solo vía SSH (deliberadamente no expuesto por web). Pide confirmación tipeando la frase exacta `BORRAR TODO` y tiene delay de 5 segundos.

```bash
ssh jlussich@192.168.68.66 calibre-wipe
```

Output de ejemplo:
```
╔═══════════════════════════════════════════════════════════════╗
║                        ⚠️  WARNING ⚠️                          ║
║                                                               ║
║  Esto va a BORRAR todos los libros de tu biblioteca Calibre.  ║
║  La acción es IRREVERSIBLE — los archivos EPUB también se     ║
║  eliminan del disco.                                          ║
╚═══════════════════════════════════════════════════════════════╝

  Biblioteca: /home/jlussich/calibre-library
  Libros actuales: 42

Para continuar, tipeá exactamente: BORRAR TODO
>
```

El script para el server durante la operación y lo reinicia al terminar (incluso si lo cancelás con Ctrl+C, un trap restaura el estado).

---

## Ingesta automática (inbox) — sin duplicados

El Pi tiene una carpeta `~/calibre-inbox/` que se procesa automáticamente **cada minuto** por un systemd timer. Workflow:

```bash
# desde tu laptop (Windows/Mac/Linux):
scp *.epub jlussich@192.168.68.66:calibre-inbox/
```

Dentro de ~1 minuto, el Pi:

1. Detecta los archivos nuevos (solo los que tienen mtime >30s, para no procesar transfers parciales)
2. Por cada uno corre `calibredb add` contra el server HTTP (no hace falta parar el server)
3. **Dedupeo automático**: si el libro ya existe (matchea por título+autor), se skipea silenciosamente — `calibredb` lo detecta solo
4. Si fue exitoso (nuevo o duplicado) → borra el archivo de `~/calibre-inbox/`
5. Si falló (corrupto, formato inválido) → mueve el archivo a `~/calibre-inbox/failed/` para que lo mires después
6. Loguea todo en `~/calibre-inbox/ingest.log`

Ventaja sobre el upload por web UI: **no agrega duplicados**. Podés tirar la misma carpeta de EPUBs 10 veces y el Pi ingresará cada libro una sola vez.

### Ver qué pasó

```bash
ssh jlussich@192.168.68.66 tail -f calibre-inbox/ingest.log
```

Ejemplo de output:
```
=== 2026-04-19T20:37:46-03:00 === ingest run (3 candidate file(s)) ===
[2026-04-19T20:37:47-03:00] OK:   Dracula.epub
[2026-04-19T20:37:48-03:00] OK:   Frankenstein.epub
[2026-04-19T20:37:48-03:00] DUPE: Dracula (2).epub (skip)
[2026-04-19T20:37:48-03:00] summary: added=2 dupes=1 failed=0
```

### Gestionar el timer

```bash
# ver próxima ejecución
systemctl --user list-timers calibre-ingest.timer

# disparar una ingesta ahora mismo (sin esperar al minuto)
systemctl --user start calibre-ingest.service

# pausarlo (si querés que el inbox no se procese por un rato)
systemctl --user stop calibre-ingest.timer

# reanudar
systemctl --user start calibre-ingest.timer
```

### Formatos soportados

El script procesa: `.epub`, `.mobi`, `.azw3`, `.pdf`, `.fb2`, `.kfx`.
Archivos con otras extensiones quedan ignorados en el inbox — podés eliminarlos a mano.

### Failed files

Si algo cae en `~/calibre-inbox/failed/`, usualmente es porque el archivo está corrupto o en un formato que Calibre no reconoce. Revisá `ingest.log` para ver el error exacto, y eliminá o re-procesá manualmente con `calibredb add`.

---

## Red y acceso

| Componente | Puerto | Acceso |
|---|---|---|
| `calibre-server` (host) | `8083` | Solo desde Docker bridges (vía UFW), no LAN directo |
| `http://calibre.pi` (Caddy) | `80` | Con basic_auth |

Caddy hace `reverse_proxy 192.168.68.66:8083` con basic_auth. UFW permite el 8083 desde los bridges de Docker (`172.17.0.0/16`, `172.18.0.0/16`, etc.) pero lo deniega desde afuera, mismo patrón que pihole.

---

## Troubleshooting

### Durante `apt install` sale "Illegal instruction" en `desktop-file-utils` / `shared-mime-info`

Bug conocido de Pi 5 con ciertos kernels: los scripts post-install de esos dos paquetes tiran SIGILL al actualizar las asociaciones del escritorio (`update-desktop-database` / `update-mime-database`). **Es cosmético** — no afectan a `calibre-server` que es headless. `install.sh` ignora el exit code de apt y verifica que el binario haya quedado instalado.

Si te molesta el error, remové el plugin que lo dispara:
```bash
sudo apt remove command-not-found
```

### El server crashea en loop, `status` muestra `restart counter at N`

Dos causas típicas:

1. **Biblioteca vacía** — `calibre-server` necesita que `~/calibre-library/metadata.db` exista. El `install.sh` lo inicializa, pero si moviste/borraste la carpeta:
   ```bash
   calibredb list --with-library ~/calibre-library
   systemctl --user restart calibre-server
   ```

2. **`libproxy.so` corrupto** — pasó una vez que el archivo `/lib/aarch64-linux-gnu/libproxy.so.0.5.9` quedó con ELF header inválido (dpkg lo dejó medio-instalado tras un error de trigger). Qt6 no puede cargar → Calibre crashea. Verificar con:
   ```bash
   file /lib/aarch64-linux-gnu/libproxy.so.0.5.9
   # Debe decir: ELF 64-bit LSB shared object, ARM aarch64
   # Si dice algo raro (SIMH tape data, etc.) → corrupto
   ```
   Fix:
   ```bash
   sudo apt install --reinstall libproxy1v5
   systemctl --user restart calibre-server
   ```

Para ver el error real, correr el server a mano:
```bash
systemctl --user stop calibre-server
/usr/bin/calibre-server --port 8083 --enable-local-write ~/calibre-library
```

### El server no arranca después de un reboot

Verificá que linger esté activado:

```bash
loginctl show-user $USER | grep Linger
```

Debe decir `Linger=yes`. Si no:

```bash
sudo loginctl enable-linger $USER
```

### Caddy devuelve 403/502 en `http://calibre.pi` después de editar el Caddyfile

Caddy usa bind-mount del archivo `Caddyfile`. Si lo editaste con una herramienta que hace atomic replace (escribir-temporal + rename), el container sigue viendo el inode viejo. Un `docker compose restart caddy` no siempre resuelve — a veces hace falta recrear:
```bash
docker compose up -d --force-recreate caddy
```

### Caddy devuelve 502 y el log dice "i/o timeout dial 192.168.68.66:8083"

Falta abrir el puerto en UFW desde los bridges de Docker. Las reglas correctas (mismas que pihole/8181):
```bash
for net in 172.17.0.0/16 172.18.0.0/16 172.19.0.0/16 172.20.0.0/16; do
    sudo ufw allow from $net to any port 8083
done
sudo ufw deny 8083
```

### El botón "Add books" no aparece o da 403 "Anonymous users are not allowed"

El service necesita dos flags:
- `--enable-local-write` — habilita la feature
- `--trusted-ips <rangos>` — le dice a calibre qué IPs clientes tratar como "locales" (Caddy conecta desde la red Docker `172.x.x.x`, no desde 192.168.x, así que por default calibre lo trata como remoto y bloquea writes)

Verificar:
```bash
systemctl --user cat calibre-server | grep ExecStart
# Debe incluir: --enable-local-write --trusted-ips 172.17.0.0/16,172.18.0.0/16,...
```

Si no, recargá el service:
```bash
cp systemd/calibre-server.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user restart calibre-server
```

Para ver qué IP fuente está usando Caddy al pegarle a calibre (por si cambió la red Docker):
```bash
tail -f ~/calibre-library/server.log
# Hacé un request a http://calibre.pi — vas a ver "Client: ::ffff:<IP>:..."
```

### Un upload de `.kfx` falla

KFX es el formato propietario de Amazon con DRM. Calibre **no puede leerlo sin plugin** (DeDRM + KFX Input — grises en términos legales, dependen de tu jurisdicción). Para libros comprados en Kindle, la alternativa legal: bajarlos como AZW3 desde tu cuenta Amazon (si Amazon lo permite para el device), o usar sources OSS donde Calibre importa directo.

### Logs

```bash
# service
systemctl --user status calibre-server
journalctl --user -u calibre-server -f

# server (log propio de calibre-server)
tail -f ~/calibre-library/server.log
```

---

## Por qué no Docker

Calibre está instalado nativamente para sobrevivir mejor a cortes de luz. El flujo es:

1. Pi bootea
2. `systemd-user@jlussich` arranca (por linger)
3. `calibre-server.service` arranca automáticamente
4. Biblioteca online

Si fuera un contenedor, la cadena sería más larga (docker daemon → compose → health checks) y hubo casos donde Docker no reinicia limpio después de un apagón abrupto.
