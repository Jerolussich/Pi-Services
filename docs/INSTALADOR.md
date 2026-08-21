# El instalador

`instalador.sh` levanta el Pi por módulos. No es un script lineal: mira el estado real del equipo y se adapta a lo que ya está hecho.

```bash
cd ~/pi-services && ./instalador.sh
```

---

## La idea

Un script de instalación común te obliga a decidir todo de entrada y correrlo de una sola vez. Este funciona distinto: **podés instalar dos módulos hoy y volver en un mes a sumar un tercero.** Detecta lo que ya funciona, no lo repite, y solo te pide los datos que le falten.

Tampoco te hace copiar y pegar comandos. Si necesita una contraseña o un token, te lo pide en el momento y te explica de dónde sacarlo. Y si no lo tenés a mano, apretás Enter, el módulo se instala igual, y al final te dice con precisión qué quedó sin completar.

---

## Los seis pasos

### 1. Diagnóstico

Antes de preguntarte nada, revisa el equipo y clasifica cada módulo en tres estados:

| | Significa |
|---|---|
| **● funcionando** | todos sus contenedores arriba y todos sus datos cargados |
| **◐ incompleto** | levanta pero le falta algo, y te dice qué |
| **○ sin instalar** | no está |

La distinción entre "funcionando" e "incompleto" importa: un módulo puede tener todos sus contenedores corriendo y aun así no servir de nada porque le falta un token. El instalador mira las dos cosas.

Para los módulos de Docker cuenta contenedores efectivamente corriendo. Para los nativos (Pi-hole, Calibre, Tailscale, firewall) consulta systemd y, en el caso de Pi-hole, hasta cuenta cuántos dominios tiene bloqueados para distinguir "instalado" de "instalado y con listas cargadas".

### 2. Elegís módulos

Un menú numerado con los doce módulos y su estado. Escribís los números separados por espacio, o usás dos atajos:

- **`todo`** para todos
- **`faltantes`** para solo lo incompleto o sin instalar

Si elegís algo que necesita Docker y el sistema base no está, lo agrega solo y te avisa. Lo mismo con Caddy: sin él no entrás a ningún servicio por su nombre, así que si elegiste servicios web te lo suma.

### 3. Elegís servicios sueltos

Acá está la parte fina. Un módulo agrupa varios contenedores, pero **no estás obligado a levantarlos todos**.

Si elegiste el módulo de noticias, te pregunta si querés los cuatro o solo algunos. Te muestra cada uno con lo que hace y si ya está corriendo:

```
  Noticias · FreshRSS, Wallabag y el filtro
     1) ● freshrss              Lector de RSS
     2) ○ wallabag              Guardar articulos para leer despues
     3) ○ news-filter           Filtra noticias por palabras clave
     4) ○ news-filter-ui        Panel para manejar las palabras clave

     Cuales (numeros, o Enter para todos):
```

Y si elegís una combinación que no cierra, te lo dice antes de hacer nada:

```
  ! news-filter necesita: freshrss wallabag
       lee de FreshRSS y guarda en Wallabag
```

No te lo impide, porque quizás los vas a levantar después. Solo te avisa.

Si no te interesa este nivel de detalle, la primera pregunta es "¿levantar todos los servicios de cada módulo?" y con un Enter salteás toda esta sección.

### 4. Pide los datos

Primero completa solo todo lo que puede deducir: rutas del repo, IP, tu usuario y grupo, zona horaria, y genera claves de sesión aleatorias. Eso no te lo pregunta.

Después te pide lo que sí necesita de vos, **de a uno**, y para cada dato te dice tres cosas: qué es, a qué archivo y variable va, y de dónde sacarlo.

```
  [3/5] Clave de API de FreshRSS
        modulo: Noticias · FreshRSS, Wallabag y el filtro
        archivo: news/news-filter/.env  ·  variable: FRESHRSS_API_PASSWORD
        Solo existe DESPUES de crear tu cuenta en freshrss.pi, en Perfil, API
        valor (Enter para saltear):
```

Las contraseñas se escriben ocultas y no quedan en el historial. La de Caddy además se convierte en hash bcrypt, con los `$` escapados como `$$`, que es el detalle que hace fallar la autenticación en silencio si se hace a mano.

**Saltear siempre es una opción válida.** Enter y sigue.

### 5. Instala

En orden de dependencias. Para cada módulo:

- Si ya funcionaba, no lo toca.
- Si es de Docker, baja las imágenes que falten y levanta **solo** los servicios que elegiste, salteando los que ya estaban arriba.
- Si es nativo, corre su instalación específica.

Al terminar cada módulo te dice cuántos contenedores quedaron arriba, y si alguno no levantó, cuál fue y con qué comando ver su log.

### 6. Resumen

Te muestra cómo quedó cada módulo elegido, y después tres listas:

**Datos que salteaste.** Cada uno con su archivo, su variable y de dónde sacarlo. Para cargarlos volvés a correr el instalador y te pide solo esos.

**Tareas pendientes.** Cosas que quedaron a medias, como reiniciar para activar log2ram o aprobar la ruta en la consola de Tailscale.

**Cuentas que tenés que crear.** Solo las de los módulos que elegiste. Eso ningún script lo puede hacer por vos.

---

## Volver a correrlo

Es la forma normal de usarlo, no una excepción.

**Para agregar un módulo:** lo elegís del menú. Los que ya funcionan ni los toca.

**Para completar datos que salteaste:** te pide solo los que falten.

**Para levantar un servicio suelto** que dejaste apagado: elegís su módulo y después solo ese servicio.

**Después de un reinicio no hace falta correrlo.** Los contenedores tienen `restart: unless-stopped` y los servicios nativos son de systemd, así que todo vuelve solo.

---

## Los módulos

| Módulo | Qué levanta |
|---|---|
| Base del sistema | zona horaria, chequeo periódico del disco, Docker, log2ram |
| Pi-hole | nativo: DNS, listas de bloqueo, los 15 registros `*.pi` |
| Caddy y Homepage | `caddy`, `homepage` |
| Monitoreo | `grafana`, `prometheus`, `node-exporter`, `pihole-exporter` |
| Noticias | `freshrss`, `wallabag`, `news-filter`, `news-filter-ui` |
| Finanzas | `itau-email-tracker`, `finance-tracker-ui` |
| Fitbit | `fitbit-exporter`, `fitbit-exporter-ui` |
| Multimedia | `jellyfin`, `qbittorrent`, `prowlarr`, `radarr`, `bazarr` |
| Ofelia | `ofelia` |
| Calibre | nativo, con su timer de ingesta |
| Tailscale | nativo, acceso remoto |
| UFW y fail2ban | firewall |

---

## Lo que el instalador sabe y no es obvio

Todo esto salió de reconstruir el Pi desde cero y chocarse con cada uno. Están resueltos adentro del script.

**La red de Docker tiene que existir antes del primer `up`.** Tres composes declaran `pi-services` como externa, porque están pensados para poder correr sueltos. En un equipo nuevo no existe, y el `up` construye las seis imágenes propias durante más de una hora para recién al final fallar con `network declared as external but could not be found`, sin levantar nada. El instalador la crea primero.

**Las imágenes se bajan de a una.** En paralelo saturan la tarjeta SD y el proceso se cuelga sin dar error. Peor: deja capas escritas a medias que después rompen contenedores de formas difíciles de rastrear. A Jellyfin le faltaba una librería de ffmpeg y a dos servicios propios les quedaron archivos de Python corruptos.

**Pi-hole tiene que soltar el puerto 80.** Viene sirviendo su panel ahí, y Caddy lo necesita. El instalador lo mueve al 8181.

**El instalador de Calibre no puede terminar por SSH.** Su último paso necesita una sesión de usuario para hablar con systemd, que no existe cuando corrés sin terminal gráfica. Deja los servicios instalados pero apagados. El instalador los habilita a mano y activa `linger` para que arranquen sin sesión abierta.

**El orden de las reglas de UFW importa.** El firewall aplica la primera que coincide, así que los permisos desde las redes de Docker tienen que ir antes que las denegaciones. Si se invierte, Caddy no llega a Calibre ni al panel de Pi-hole.

**Todos los `.env` tienen que existir**, aunque solo levantes un módulo. Docker Compose lee la configuración completa y falla si le falta uno. El instalador los crea todos, pero solo te pide datos de los módulos que elegiste.

**El hash de Caddy necesita los `$` duplicados.** Compose interpreta `$` como variable, así que un hash sin escapar rompe la autenticación sin decir por qué.

---

## Si algo sale mal

**Se corta a la mitad.** Volvé a correrlo. Detecta lo que quedó hecho y sigue.

**Un contenedor no levanta.** El resumen te dice cuál y el comando para ver su log.

**El firewall te dejó afuera.** No debería: el instalador activa una red de seguridad que lo desactiva sola a los 4 minutos si no confirmás que seguís entrando. Si igual pasa, entrá por monitor y teclado y corré `sudo ufw disable`.

**`sudo` pide contraseña.** El instalador no puede trabajar así y te lo dice al arrancar, con el comando exacto para arreglarlo.

---

## Opciones

```bash
./instalador.sh
```

No tiene banderas. Todo se elige desde los menús, para que alguien sin contexto pueda usarlo sin leer documentación.

Para la operación diaria, ver [OPERACION.md](OPERACION.md).
