# El instalador

`instalador.sh` levanta el Pi por módulos. No es un script lineal: mira el estado real del equipo y se adapta a lo que ya está hecho.

```bash
cd ~/pi-services && ./instalador.sh
```

---

## La idea

Un script de instalación común te obliga a decidir todo de entrada y correrlo de una sola vez. Este funciona distinto: **podés instalar dos módulos hoy y volver en un mes a sumar un tercero.** Detecta lo que ya funciona, no lo repite, y solo te pide los datos que le falten.

Tampoco te hace copiar y pegar comandos. Si necesita una contraseña o un token, te lo pide en el momento y te explica de dónde sacarlo. Y si no lo tenés a mano, apretás Enter, el módulo se instala igual, y al final te dice con precisión qué quedó sin completar.

Y no se queda en levantar contenedores: **también los configura**. Deja a Jellyfin con tu usuario y la biblioteca creada, a Radarr y Sonarr apuntando a sus carpetas y hablando con qBittorrent, y a Prowlarr enlazado con los dos. Todo eso antes de que abras el navegador por primera vez.

---

## Los ocho pasos

### 1. Diagnóstico

Antes de preguntarte nada, revisa el equipo y clasifica cada módulo en tres estados:

| | Significa |
|---|---|
| **● funcionando** | todos sus contenedores arriba y todos sus datos cargados |
| **◐ incompleto** | levanta pero le falta algo, y te dice qué |
| **○ sin instalar** | no está |

La distinción entre "funcionando" e "incompleto" importa: un módulo puede tener todos sus contenedores corriendo y aun así no servir de nada porque le falta un token. El instalador mira las dos cosas.

Para los módulos de Docker cuenta contenedores efectivamente corriendo. Para los nativos (Pi-hole, Tailscale, firewall) consulta systemd y, en el caso de Pi-hole, hasta cuenta cuántos dominios tiene bloqueados para distinguir "instalado" de "instalado y con listas cargadas".

Y después del resumen te dice **exactamente qué datos faltan**, no solo cuántos, separando dos casos que son muy distintos:

```
━━━ Datos que faltan en lo que ya tenes levantado ━━━

! Estos servicios estan corriendo pero no pueden hacer su trabajo
  hasta que cargues estos datos.

  Noticias · FreshRSS, Wallabag y el filtro
     · Clave de API de FreshRSS
           va en:  news/news-filter/.env  ->  FRESHRSS_API_PASSWORD=
           donde:  Solo existe DESPUES de crear tu cuenta en freshrss.pi, en Perfil, API
```

Lo que ya está corriendo y le falta un dato es **lo urgente**: el contenedor está ahí ocupando memoria y sin poder trabajar. Lo que todavía no levantaste es informativo, para que sepas qué te va a pedir si lo elegís.

Esto hace que correr el instalador sirva también solo para preguntar: entrás, mirás qué falta, y salís sin tocar nada dejando el menú en blanco.

**No mira solo variables de entorno.** Algunos servicios necesitan un archivo, no una variable: el token de OAuth de Fitbit, el de Microsoft Graph para el lector del banco, la lista de palabras clave del filtro. Sin contarlos, el instalador reportaría esos módulos como "funcionando" aunque no puedan hacer absolutamente nada, que es la peor forma de mentir.

Y los crea vacíos antes de levantar los contenedores, por una razón concreta: **si Compose monta un archivo que no existe, Docker crea un directorio con ese nombre**. El servicio después nunca puede escribir ahí y falla de una forma bastante difícil de rastrear. Si encuentra uno mal creado, lo corrige.

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

**Saltear siempre es una opción válida.** Enter y sigue.

#### Una sola contraseña

Las contraseñas no se piden una por una. Se pide **una sola vez, al principio**, y esa misma va a todos lados: la homepage, los paneles propios, y las cuentas que el instalador crea solo en Jellyfin, qBittorrent, Radarr, Sonarr, Prowlarr, Bazarr, Grafana y Pi-hole.

Es a propósito. La versión anterior pedía una contraseña por servicio y era fácil terminar con dos distintas sin darte cuenta: el hash de Caddy generado con una y los paneles con otra. Después no entrabas a la homepage y no había forma de saber por qué.

Si querés una distinta para algún servicio puntual, decís que sí a la pregunta que viene después y te la pide servicio por servicio, con Enter para usar la general en los que no te importe.

Se escriben ocultas y no quedan en el historial. La de Caddy además se convierte en hash bcrypt, con los `$` escapados como `$$`, que es el detalle que hace fallar la autenticación en silencio si se hace a mano.

**Una excepción, y es de qBittorrent, no del instalador:** rechaza contraseñas de menos de 6 caracteres. Si la tuya es más corta y elegiste el módulo de multimedia, te avisa en el momento de elegirla y te deja decidir: cambiarla por una de 6 o más y seguir teniendo una sola, o dejar la corta y ponerle una aparte solo a qBittorrent.

### 5. Instala

En orden de dependencias. Para cada módulo:

- Si ya funcionaba, no lo toca.
- Si es de Docker, baja las imágenes que falten y levanta **solo** los servicios que elegiste, salteando los que ya estaban arriba.
- Si es nativo, corre su instalación específica.

Al terminar cada módulo te dice cuántos contenedores quedaron arriba, y si alguno no levantó, cuál fue y con qué comando ver su log.

### 6. Configura los servicios solo

Levantar un contenedor no alcanza. Jellyfin recién levantado te recibe con un asistente de cinco pantallas, Radarr no sabe dónde guardar las películas, y qBittorrent viene apuntando a una carpeta que en este stack no existe. Todo eso lo hace el instalador antes de que abras el navegador.

Las llamadas salen desde adentro de cada contenedor contra su propio `localhost`, porque ninguno publica su puerto al host. Casi todos traen `curl`; a los que no, el instalador los consulta desde el host por su IP de Docker.

| Servicio | Qué deja hecho |
|---|---|
| **Jellyfin** | Completa el asistente entero, crea tu usuario, arma las bibliotecas de Películas (`/media/movies`) y Series (`/media/tv`), y activa la decodificación por hardware con VAAPI |
| **qBittorrent** | Lee la contraseña temporal del log, la reemplaza por la tuya, y corrige las rutas de descarga a `/data/downloads` |
| **Radarr** y **Sonarr** | Carpeta raíz (`/data/media/movies` y `/data/media/tv`), hardlinks activados, qBittorrent conectado, y el perfil de calidad **Perfeccionista** |
| **Prowlarr** | Lo enlaza con Radarr y Sonarr, así los indexers que cargues se sincronizan solos a los dos |
| **Bazarr** | Lo conecta a Radarr y a Sonarr, y le crea el **perfil de idiomas** con Español e Inglés |
| **Seerr** | Crea tu usuario contra Jellyfin, habilita las dos bibliotecas, y conecta Radarr y Sonarr pidiendo con el perfil Perfeccionista |
| **Homepage** | Lee las API keys de Radarr, Sonarr, Prowlarr y Seerr y las escribe en su `.env`, así los recuadros muestran datos en vivo |
| **Grafana** | Le pone la contraseña de admin, así no te pide cambiarla en el primer login |
| **Pi-hole** | Le pone la contraseña del panel y **genera su clave de API** para las métricas |
| **FreshRSS** | Hace el asistente entero, crea tu usuario y **habilita la API con su clave** |
| **Wallabag** | Le cambia la contraseña de fábrica y **le crea el cliente de API** que usa el filtro |
| **Home Assistant** | Deja `configuration.yaml` listo antes del primer arranque y abre su puerto solo para Caddy. Es el único que **no puede terminar solo**, y abajo está por qué |

#### Las tres cuentas que ya no tenés que crear

Este es el cambio que más se nota. Antes, tres servicios te cortaban la instalación a la mitad: para seguir había que abrir el navegador, crear una cuenta, y volver a pegar un token en un `.env`.

No eran elecciones tuyas. Eran trámites.

| | Antes | Ahora |
|---|---|---|
| **FreshRSS** | asistente de 4 pantallas + crear la clave de API | un comando: `do-install.php` y `create-user.php` con `--api-password` |
| **Wallabag** | cambiar la contraseña + crear el cliente de API a mano | contraseña por su consola, cliente escrito en su base y **comprobado pidiendo un token** |
| **Pi-hole** | pasar el panel a modo Expert y generar una app password | su propia API la genera, el instalador guarda el hash y se queda la clave |

La lista de "datos que te pido después de crear una cuenta" **quedó vacía**. Eran cinco.

Queda una excepción honesta: si FreshRSS **ya estaba instalado**, el instalador no lo toca. Su clave de API se guarda hasheada y no se puede releer ni cambiar desde afuera para un usuario que ya existe, así que en ese caso sigue siendo tuya y te lo dice.

#### El perfil de idiomas de Bazarr

Es el paso que más se olvida de todo el stack, y el que peor avisa: sin un perfil de idiomas, Bazarr corre, se ve sano, aparece conectado a Radarr y a Sonarr, y **no baja un solo subtítulo nunca**.

Queda creado con Español e Inglés. Qué idiomas querés es tuyo, así que el instalador te dice dónde cambiarlo en vez de dar por sentado que acertó.

#### El perfil de calidad

Radarr y Sonarr quedan con un perfil llamado **Perfeccionista**, que acepta todas las calidades y tiene el corte arriba de todo con la mejora automática activada. Traducido: agarra lo que haya, y cuando aparece una versión mejor la reemplaza sola.

Quedan afuera **BR-DISK** y **Raw-HD**, que son el disco entero sin comprimir: pesan decenas de gigas y en un Pi 5 obligan a transcodificar.

No lo escribe a mano. Le pide a cada servicio su propio esquema de calidades con `GET /qualityprofile/schema`, lo marca entero y devuelve el resultado. Así el perfil sale correcto aunque Radarr y Sonarr tengan listas distintas, que es el caso, y sigue saliendo correcto cuando una versión nueva agregue calidades.

#### Las claves de la homepage

Los recuadros de la homepage muestran datos en vivo (cuántas películas tenés, qué se está bajando) solo si tienen la API key del servicio. Copiarlas a mano son cuatro viajes de ida y vuelta entre paneles.

El instalador las lee de la configuración de cada servicio y las escribe en `homepage/.env`. **Vos nunca ves ni copiás una clave**, y si alguna vez regenerás una, volvés a correr el instalador y se actualiza sola.

Y a Radarr, Sonarr, Prowlarr y Bazarr **les pone contraseña**, que es más importante de lo que parece: los tres vienen de fábrica con `authenticationMethod: none`, y Caddy tampoco les pide nada porque se asume que traen la suya. Sin este paso quedan abiertos a cualquiera en tu red.

Dos reglas gobiernan todo el paso:

**No pisa nada.** Si algo ya está configurado, lo dice y sigue. Podés correr el instalador diez veces seguidas sin miedo.

**No deja un servicio peor de como lo encontró.** Si un paso falla, avisa con el error textual y lo anota como pendiente, en vez de romper. El caso más claro es Bazarr: después de ponerle contraseña **verifica que se pueda entrar**, y si el login no funciona se la saca, porque un hash mal calculado te dejaría afuera de tu propio Bazarr sin forma de volver.

El orden importa y no es casual: qBittorrent antes que Radarr, porque Radarr necesita su contraseña para conectarse; y Radarr antes que Prowlarr y Bazarr, porque los dos se enganchan contra él.

### 7. Te guía con lo que queda

Después de todo eso queda poco, y de dos tipos: **elecciones que son tuyas** (qué trackers usás, de dónde bajar los subtítulos, qué complementos querés en Jellyfin) y **la cuenta de Home Assistant**, que es la única que no se puede automatizar de verdad.

Son **cuatro pantallas**. Antes eran seis, y la mitad eran cuentas que había que crear a mano solo para poder copiar un token de vuelta. Esas ya no están.

```
  [2/4]  prowlarr   Cargar los indexers que uses
        http://prowlarr.pi

        1. Entra con admin y tu contrasena. Ya se la configure.
        2. Anda a Indexers, boton Add Indexer, y busca los que uses.
        3. Cada uno te pide sus datos: los publicos no piden nada, los
           privados piden la cuenta que tengas en ese tracker.
        4. No hace falta que los cargues tambien en Radarr. Ya enlace los
           dos: lo que agregues aca se le sincroniza a Radarr solo.

        Enter cuando termines (o 's' para saltear):
```

Los pasos también te dicen **qué no tenés que hacer**, que es igual de útil: no cargues los indexers en Radarr, porque Prowlarr se los sincroniza; no toques la pestaña de Radarr en Bazarr, porque ya está conectada; y no armes el perfil de idiomas, porque ya está.

Si algún dato quedara pendiente, el instalador te lo pide acá mismo, apenas terminás el paso del que sale, en el momento en que lo tenés en pantalla. Ese mecanismo sigue estando aunque hoy no lo use ninguno.

Saltear siempre es válido: apretás `s` y queda anotado como pendiente.

### 8. Resumen

Te muestra cómo quedó cada módulo elegido, y después tres listas:

**Datos que salteaste.** Cada uno con su archivo, su variable y de dónde sacarlo. Para cargarlos volvés a correr el instalador y te pide solo esos.

**Tareas pendientes.** Cosas que quedaron a medias, como reiniciar para activar log2ram o aprobar la ruta en la consola de Tailscale.

**Con qué entrás a cada cosa.** La lista de URLs de lo que instalaste, con el recordatorio de que el usuario es `admin` en todas y la contraseña es la que elegiste. FreshRSS y Wallabag van aparte, porque esas cuentas las creaste vos.

---

## Las listas de bloqueo

El módulo de Pi-hole te deja elegir cuánto querés bloquear, en vez de imponerte una lista:

```
     HaGeZi publica varias, de menos a mas agresiva:

     1)  Light        ~60.000 dominios   lo minimo, no rompe nada
     2)  Multi        ~180.000           equilibrio para el dia a dia
     3)  Pro          ~250.000           agrega rastreo y telemetria
     4)  Pro++        ~300.000           suma telemetria de sistemas operativos
     5)  Ultimate     ~365.000           la mas estricta que hay
     6)  Otra URL     pegas la que quieras
     7)  Ninguna      dejar solo la que Pi-hole trae de fabrica
```

Podés elegir varias a la vez, o pegar la URL de cualquier lista que uses. Antes de meterla en la base **verifica que la URL responda**, así no te quedás con una lista rota que falla en silencio cada vez que actualiza.

Después te ofrece bloquear **dominios sueltos**, por ejemplo una red social. Lo hace con una expresión que agarra el dominio y todos sus subdominios, así bloquear `reddit.com` también cubre `www.reddit.com` y `old.reddit.com`.

Si ya tenías listas cargadas, primero te pregunta si querés tocarlas. Si le decís que no, no las toca.

Un aviso que el instalador te da y vale repetir: **cuanto más estricta la lista, más chances de que algo legítimo deje de andar**. Si eso pasa, se arregla desde el panel de Pi-hole, en `Domains`, agregando el dominio a la lista de permitidos.

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
| Multimedia | `jellyfin`, `seerr`, `qbittorrent`, `prowlarr`, `radarr`, `sonarr`, `bazarr` |
| Casa | `homeassistant` |
| Ofelia | `ofelia` |
| Tailscale | nativo, acceso remoto |
| UFW y fail2ban | firewall |

---

## Lo que el instalador sabe y no es obvio

Todo esto salió de reconstruir el Pi desde cero y chocarse con cada uno. Están resueltos adentro del script.

**La red de Docker tiene que existir antes del primer `up`.** Tres composes declaran `pi-services` como externa, porque están pensados para poder correr sueltos. En un equipo nuevo no existe, y el `up` construye las seis imágenes propias durante más de una hora para recién al final fallar con `network declared as external but could not be found`, sin levantar nada. El instalador la crea primero.

**Las imágenes se bajan de a una.** En paralelo saturan la tarjeta SD y el proceso se cuelga sin dar error. Peor: deja capas escritas a medias que después rompen contenedores de formas difíciles de rastrear. A Jellyfin le faltaba una librería de ffmpeg y a dos servicios propios les quedaron archivos de Python corruptos.

**Pi-hole tiene que soltar el puerto 80.** Viene sirviendo su panel ahí, y Caddy lo necesita. El instalador lo mueve al 8181.

**El orden de las reglas de UFW importa.** El firewall aplica la primera que coincide, así que los permisos desde las redes de Docker tienen que ir antes que las denegaciones. Si se invierte, Caddy no llega al panel de Pi-hole.

**Todos los `.env` tienen que existir**, aunque solo levantes un módulo. Docker Compose lee la configuración completa y falla si le falta uno. El instalador los crea todos, pero solo te pide datos de los módulos que elegiste.

**El hash de Caddy necesita los `$` duplicados.** Compose interpreta `$` como variable, así que un hash sin escapar rompe la autenticación sin decir por qué.

**Radarr, Prowlarr y Bazarr salen de fábrica sin contraseña.** Vienen con `authenticationMethod: none`, y Caddy tampoco les pone la suya porque se asume que traen login propio. El resultado es que quedan abiertos en la red. El instalador les configura autenticación por formulario.

**qBittorrent viene apuntando a `/downloads`, que en este stack no existe.** El DAS se monta en `/data`, en los cinco contenedores. Si no se corrige, las descargas caen adentro del contenedor y encima se pierde el hardlink con la biblioteca, así que cada película termina ocupando el doble.

**qBittorrent no acepta contraseñas de menos de 6 caracteres.** Contesta `400` con el motivo en el cuerpo, y si no se lee ese cuerpo el fallo parece un éxito. Peor: la contraseña queda sin cambiar y después Radarr no se puede conectar, así que un error silencioso se convierte en dos.

**Su login contesta `204`, no `Ok.`** La versión 5 cambió la respuesta. Verificar contra el texto `Ok.` da falso negativo con un login que en realidad funcionó.

**Y reescribe su configuración al apagarse.** Editar `qBittorrent.conf` con el contenedor andando no sirve de nada: al reiniciar la pisa con lo que tenía en memoria. Hay que parar el contenedor primero.

**Bazarr no se configura por API, y su contenedor no trae PyYAML alcanzable.** Su configuración vive en un YAML, así que el instalador lo saca del contenedor, lo edita con el Python del sistema, y lo vuelve a escribir sobre el mismo archivo para no cambiarle el dueño.

**Bazarr guarda la contraseña del panel como md5.** Un hash mal calculado te deja afuera sin forma de entrar, así que el instalador verifica el login después de ponerla y se la saca si no funciona.

**Jellyfin se configura entero por sus endpoints `/Startup`**, que no piden autenticación mientras el asistente esté sin terminar. Después de cerrarlo hay que autenticarse para todo lo demás.

**La Pi 5 decodifica por hardware pero no codifica.** Al activar VAAPI hay que dejar la codificación por hardware apagada, o cada transcodificación falla.

**Jellyfin necesita las dos bibliotecas, no una.** Con solo la de Películas, Seerr no puede marcar las series como disponibles y te las ofrece para pedir aunque ya las tengas bajadas.

**El primer arranque de Seerr no se puede repetir.** El POST a `/api/v1/auth/jellyfin` crea el usuario dueño, y correrlo dos veces no es idempotente. El instalador comprueba antes si ya hay usuarios y, si los hay, no lo toca.

**La imagen de Seerr no trae `curl`.** Es la única del stack que no lo tiene, así que el `docker exec curl` que se usa con todas las demás ahí falla. El instalador la consulta desde el host por su IP de Docker, que además es más honesto: prueba el mismo camino que va a usar Caddy.

**Seerr va último.** No se puede configurar solo: necesita que Jellyfin ya tenga bibliotecas y que Radarr y Sonarr ya existan con su carpeta raíz. Si se hace antes, guarda conexiones vacías sin quejarse.

**Home Assistant va en la red del host, y es el único.** Descubre los dispositivos de la casa por mDNS, SSDP y DHCP, que son protocolos de difusión y no atraviesan el puente de Docker. En el puente arranca igual y parece sano, pero no encuentra nada solo. No rompe la regla del repo, porque la regla nunca fue "todo en el puente" sino **"nada se expone salvo por Caddy en el 80"**: el 8123 queda cerrado por UFW igual que el 8181 de Pi-hole.

**Y detrás de Caddy tira `400 Bad Request` si no se lo avisa.** Ve todas las visitas viniendo de la IP de Caddy y las rechaza. El síntoma es una pantalla en blanco que no menciona proxies por ningún lado. Por eso el instalador deja `trusted_proxies` escrito **antes** del primer arranque, no después.

**Pero escribirlo no alcanza: hay que confirmarlo, y solo lo podés confirmar vos.** Home Assistant no se cree la configuración nueva porque se la pidas. La aplica como `pending` y espera confirmación; si en cinco minutos no llega, la revierte, la marca `not_promoted` y `casa.pi` contesta 400 a partir de ahí.

Lo que confirma no es cualquier pedido: tiene que ser un pedido **autenticado que llegue por el proxy**. Y para que exista un pedido autenticado tiene que existir un usuario, que se crea en el asistente de bienvenida.

O sea que la cadena se cierra recién cuando entrás a `casa.pi` y creás tu cuenta. **Es el único servicio del repo que el instalador no puede terminar**, y no por falta de código: un `curl` sin sesión devuelve 302 y parece que anda, pero no confirma nada y cinco minutos después vuelve el 400. Está comprobado.

Así que el instalador deja todo listo hasta donde se puede (el puerto abierto, la configuración escrita, y el `pending` fresco si estaba quemado) y te dice el paso que falta con la parte que importa: **entrá por `casa.pi`, no por la IP con `:8123`**, porque un login por la IP no pasa por el proxy y no confirma nada.

Ese es también el peor error posible de diagnosticar si no lo sabés: `configuration.yaml` dice exactamente lo correcto, el contenedor está sano, y el log no menciona proxies hasta que ya es tarde.

**Un servicio nuevo en la red del host necesita su regla de UFW, o Caddy contesta 502.** Y esa lista estaba escrita a mano con un solo puerto adentro, el 8181 de Pi-hole. Ahora sale del Caddyfile, igual que los registros DNS: los destinos que empiezan con un número son del host, los que empiezan con una letra son contenedores.

**Un contenedor en la red del host no tiene IP, pero `docker inspect` no devuelve vacío: devuelve el texto `invalid IP`.** Es lo que imprime el template de Go cuando el campo no aplica. Si no se filtra, se arma una URL `http://invalid:8123`, falla, y un servicio perfectamente sano figura como caído. El diagnóstico reportó a Home Assistant como muerto por esto. Ahora tanto el instalador como el diagnóstico preguntan por la misma función, `ip_de`, que devuelve `127.0.0.1` para los de red del host.

**Su historial es lo que más escribe en la tarjeta.** El `recorder` guarda cada cambio de cada entidad y de fábrica retiene 10 días. Queda en 3, con confirmación cada 30 segundos y sacando las entidades que cambian cada pocos segundos.

**`pihole setpassword --help` no muestra ayuda: te cambia la contraseña a `--help`.**

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
