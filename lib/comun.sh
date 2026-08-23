#!/bin/bash
# ==============================================================================
#  lib/comun.sh  ·  Lo que saben en comun el instalador y el diagnostico
#
#  No se ejecuta solo: se carga con source desde instalador.sh y diagnostico.sh.
#
#  Aca vive TODO el conocimiento sobre los servicios: como se llaman, que
#  necesitan, como se detecta su estado, y como se configuran. La razon de que
#  este separado es que si el instalador y el diagnostico tuvieran cada uno su
#  propia idea de que significa "Radarr esta bien", en tres meses dirian cosas
#  distintas del mismo servicio.
# ==============================================================================

set -uo pipefail

# Este archivo vive en lib/, asi que la raiz del repo es la carpeta de arriba.
# Todo lo demas asume estar parado ahi: las rutas de los .env son relativas.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

IP_FIJA="192.168.68.66"
MASCARA="22"
GATEWAY="192.168.68.1"

V=$'\e[0;32m'; R=$'\e[0;31m'; A=$'\e[1;33m'; C=$'\e[0;36m'
G=$'\e[0;90m'; B=$'\e[1m'; N=$'\e[0m'

ok()      { echo "  ${V}✓${N} $*"; }
falla()   { echo "  ${R}✗${N} $*"; }
aviso()   { echo "  ${A}!${N} $*"; }
info()    { echo "    $*"; }
gris()    { echo "  ${G}$*${N}"; }
titulo()  { echo ""; echo "${B}${C}━━━ $* ━━━${N}"; echo ""; }

PENDIENTES=()
pendiente() { PENDIENTES+=("$1"); }

# "1 dato" y no "1 datos". Los mensajes de estado pluralizaban siempre.
plural() { [ "$1" = "1" ] && echo "$2" || echo "$3"; }

# Los nombres que sirve Caddy, leidos del Caddyfile.
#
# Antes esta lista estaba escrita a mano adentro del instalador, asi que
# agregar un servicio obligaba a acordarse de tocarla en dos lados. Cuando uno
# se olvidaba, el servicio quedaba levantado y sin resolver, y el sintoma era
# un error de DNS que no parece tener nada que ver con haber agregado algo.
# Derivandola del Caddyfile, agregar el bloque alcanza.
hosts_del_caddyfile() {
    grep -oE '^http://[a-z0-9.-]+' "$REPO/caddy/Caddyfile" 2>/dev/null \
        | sed 's|http://||' | grep -v '^$' | sort -u
}

# El puerto interno de un servicio, tambien del Caddyfile.
#
# Misma idea que los registros DNS: el dato ya esta escrito una vez, en la
# linea reverse_proxy. Tenerlo ademas en una tabla aparte adentro del
# diagnostico era pedir que las dos se separaran, y cuando se separan el
# sintoma es un servicio sano reportado como caido, que es peor que no
# comprobarlo.
puerto_de() {
    [ "$1" = "caddy" ] && { echo 80; return; }
    grep -oE "reverse_proxy +$1:[0-9]+" "$REPO/caddy/Caddyfile" 2>/dev/null \
        | head -1 | grep -oE '[0-9]+$'
}

DOCKER="sudo docker"

# Una sola contrasena para todo. Se pregunta una vez y se usa en todos lados:
# el hash de Caddy, los paneles propios, y las cuentas de los servicios que el
# instalador crea solo. Podes pedir una distinta para alguno, pero es explicito.
CLAVE_MAESTRA=""
CLAVE_POR_SERVICIO=0

# ══════════════════════════════════════════════════════════════════════════════
#  DEFINICION DE MODULOS
#
#  Cada modulo declara: nombre visible, servicios Docker, archivos .env,
#  y si es nativo (fuera de Docker).
# ══════════════════════════════════════════════════════════════════════════════

MODULOS=(sistema pihole core monitoring news finance fitbit media ofelia tailscale seguridad)

declare -A NOMBRE=(
  [sistema]="Base del sistema"
  [pihole]="Pi-hole  ·  DNS y bloqueo de publicidad"
  [core]="Caddy y Homepage  ·  la puerta de entrada"
  [monitoring]="Monitoreo  ·  Grafana y Prometheus"
  [news]="Noticias  ·  FreshRSS, Wallabag y el filtro"
  [finance]="Finanzas  ·  lector de mails del banco"
  [fitbit]="Fitbit  ·  datos de salud"
  [media]="Multimedia  ·  Jellyfin, Radarr, Sonarr, Prowlarr, Bazarr"
  [ofelia]="Ofelia  ·  programador de tareas"
  [tailscale]="Tailscale  ·  acceso remoto"
  [seguridad]="UFW y fail2ban  ·  firewall"
)

declare -A DESCRIPCION=(
  [sistema]="Zona horaria, chequeo periodico del disco, Docker y log2ram."
  [pihole]="Resuelve los nombres *.pi de todos tus servicios y bloquea publicidad en toda la red. Va nativo para que responda aunque Docker se caiga."
  [core]="Caddy recibe TODO el trafico web y lo reparte. Sin esto no entras a ningun servicio por su nombre."
  [monitoring]="Tableros con metricas del sistema, de Pi-hole, y de tus datos de Fitbit y finanzas."
  [news]="Lector de RSS, guardado de articulos para leer despues, y un filtro por palabras clave."
  [finance]="Lee los mails del banco y arma tus movimientos. Necesita autorizacion de Microsoft."
  [fitbit]="Baja tu actividad, sueno y ejercicios. Necesita una app registrada en Fitbit."
  [media]="Descarga, organiza, subtitula y reproduce. Necesita un disco externo montado."
  [ofelia]="Dispara las tareas programadas del resto de los contenedores."
  [tailscale]="Entras a tus servicios desde afuera de casa sin abrir puertos. Tambien te da SSH de emergencia si Docker se rompe."
  [seguridad]="Cierra todo salvo lo necesario y banea intentos de fuerza bruta."
)

declare -A SERVICIOS=(
  [core]="caddy homepage"
  [monitoring]="grafana prometheus node-exporter pihole-exporter"
  [news]="freshrss wallabag news-filter news-filter-ui"
  [finance]="itau-email-tracker finance-tracker-ui"
  [fitbit]="fitbit-exporter fitbit-exporter-ui"
  [media]="jellyfin qbittorrent prowlarr radarr sonarr bazarr"
  [ofelia]="ofelia"
)

declare -A NATIVO=( [sistema]=1 [pihole]=1 [tailscale]=1 [seguridad]=1 )

# Que hace cada servicio suelto, para poder elegirlos de a uno
declare -A QUE_HACE=(
  [caddy]="Proxy inverso. Recibe todo el trafico y lo reparte por nombre"
  [homepage]="Panel de inicio con enlaces a todo"
  [grafana]="Tableros de metricas"
  [prometheus]="Recolecta y guarda las metricas"
  [node-exporter]="Expone metricas del sistema (CPU, RAM, disco)"
  [pihole-exporter]="Expone metricas de Pi-hole"
  [freshrss]="Lector de RSS"
  [wallabag]="Guardar articulos para leer despues"
  [news-filter]="Filtra noticias por palabras clave"
  [news-filter-ui]="Panel para manejar las palabras clave"
  [itau-email-tracker]="Lee los mails del banco"
  [finance-tracker-ui]="Panel de movimientos y carga de PDFs"
  [fitbit-exporter]="Baja tus datos de Fitbit"
  [fitbit-exporter-ui]="Panel para la ingesta manual"
  [jellyfin]="Servidor multimedia"
  [qbittorrent]="Cliente de descargas"
  [prowlarr]="Gestor central de indexers"
  [radarr]="Automatiza peliculas"
  [sonarr]="Automatiza series"
  [bazarr]="Descarga subtitulos"
  [ofelia]="Programador de tareas"
)

# Servicios que no sirven de nada sin otro. Formato: servicio|de que depende|por que
DEPENDENCIAS=(
  "news-filter|freshrss wallabag|lee de FreshRSS y guarda en Wallabag"
  "news-filter-ui|news-filter|es el panel del filtro"
  "radarr|prowlarr qbittorrent|Prowlarr le da los indexers y qBittorrent descarga"
  "sonarr|prowlarr qbittorrent|Prowlarr le da los indexers y qBittorrent descarga"
  "bazarr|radarr sonarr|toma de Radarr y Sonarr que subtitular"
  "finance-tracker-ui|itau-email-tracker|muestra lo que el tracker recolecta"
  "fitbit-exporter-ui|fitbit-exporter|es el panel del exporter"
  "grafana|prometheus|sin Prometheus no tiene de donde leer las metricas"
  "homepage|caddy|se entra por Caddy"
)

# Modulos que si o si tienen que estar
REQUERIDOS="core"

# ══════════════════════════════════════════════════════════════════════════════
#  DEFINICION DE VARIABLES
#
#  Para cada variable: a que archivo va, que es, y como se obtiene.
#  Tipo:  auto    la calcula el script
#         clave   contrasena, se pide oculta
#         hash    contrasena que se convierte en hash bcrypt
#         texto   valor comun
#         token   dato externo que hay que ir a buscar a otro lado
# ══════════════════════════════════════════════════════════════════════════════

# formato:  modulo|archivo|VARIABLE|tipo|descripcion|como conseguirlo
VARIABLES=(
"core|caddy/.env|CADDY_USER|auto|Usuario de la autenticacion|"
"core|caddy/.env|CADDY_PASSWORD_HASH|hash|Contrasena de homepage y prometheus|La eligis vos ahora"
"core|homepage/.env|PI_IP|auto|IP de la Pi|"
"monitoring|monitoring/.env|FITBIT_EXPORTS_PATH|auto|Ruta de los datos de Fitbit|"
"monitoring|monitoring/.env|FINANCE_DATA_PATH|auto|Ruta de los datos de finanzas|"
"monitoring|monitoring/.env|PIHOLE_API_KEY|token|Clave para leer metricas de Pi-hole|Panel de Pi-hole, Settings, API, Generate app password"
"news|news/wallabag/.env|PI_IP|auto|IP de la Pi|"
"news|news/news-filter/ui/.env|UI_USERNAME|auto|Usuario del panel|"
"news|news/news-filter/ui/.env|UI_PASSWORD|clave|Contrasena del panel de noticias|La eligis vos ahora"
"news|news/news-filter/ui/.env|SECRET_KEY|auto|Clave de sesion aleatoria|"
"news|news/news-filter/.env|FRESHRSS_API_PASSWORD|token|Clave de API de FreshRSS|Solo existe DESPUES de crear tu cuenta en freshrss.pi, en Perfil, API"
"news|news/news-filter/.env|WALLABAG_CLIENT_ID|token|ID de cliente de Wallabag|Solo existe DESPUES de crear tu cuenta en wallabag.pi, en Config, Clientes API"
"news|news/news-filter/.env|WALLABAG_CLIENT_SECRET|token|Secreto de cliente de Wallabag|Mismo lugar que el ID"
"news|news/news-filter/.env|WALLABAG_PASSWORD|clave|Contrasena de tu cuenta de Wallabag|La que pongas al crear la cuenta"
"finance|finance/finance-tracker/.env|UI_USERNAME|auto|Usuario del panel|"
"finance|finance/finance-tracker/.env|UI_PASSWORD|clave|Contrasena del panel de finanzas|La eligis vos ahora"
"finance|finance/finance-tracker/.env|SECRET_KEY|auto|Clave de sesion aleatoria|"
"fitbit|fitbit-exporter/ui/.env|UI_USERNAME|auto|Usuario del panel|"
"fitbit|fitbit-exporter/ui/.env|UI_PASSWORD|clave|Contrasena del panel de Fitbit|La eligis vos ahora"
"fitbit|fitbit-exporter/ui/.env|SECRET_KEY|auto|Clave de sesion aleatoria|"
"media|media/.env|PUID|auto|Usuario dueno de los archivos|"
"media|media/.env|PGID|auto|Grupo dueno de los archivos|"
"media|media/.env|TZ|auto|Zona horaria|"
"media|media/.env|DAS_ROOT|texto|Donde esta montado el disco externo|Si todavia no lo tenes, dejalo en /mnt/das"
"media|media/.env|JELLYFIN_PublishedServerUrl|auto|URL con la que Jellyfin se anuncia|"
"media|media/.env|QBIT_TORRENT_PORT|auto|Puerto de conexiones entrantes|"
"news|news/news-filter/.env|FRESHRSS_USERNAME|texto|Tu usuario de FreshRSS|El nombre con el que creaste la cuenta. Por defecto: admin"
"news|news/news-filter/.env|WALLABAG_USERNAME|texto|Tu usuario de Wallabag|El nombre con el que creaste la cuenta. Por defecto: wallabag"
)

# ══════════════════════════════════════════════════════════════════════════════
#  ARCHIVOS QUE HACEN FALTA Y NO SON VARIABLES
#
#  Algunos servicios necesitan un archivo, no una variable de entorno: tokens
#  de OAuth, listas de palabras. Sin esto el instalador reportaria el modulo
#  como "funcionando" aunque no pueda hacer absolutamente nada.
#
#  Ademas importa crearlos ANTES de levantar el contenedor: si el compose
#  monta un archivo que no existe, Docker crea un DIRECTORIO con ese nombre
#  y el servicio nunca puede escribir ahi.
# ══════════════════════════════════════════════════════════════════════════════

# modulo|ruta|descripcion|como conseguirlo|plantilla|marcador de "sin completar"
ARCHIVOS=(
"fitbit|fitbit-exporter/tokens.json|Credenciales OAuth de Fitbit|Registra una app en dev.fitbit.com y corre el flujo de autorizacion, ver fitbit-exporter/README.md|fitbit-exporter/tokens.json.example|YOUR_CLIENT_ID"
"finance|finance/finance-tracker/data/token.json|Token de Microsoft Graph|Se genera autorizando por codigo de dispositivo, ver finance/finance-tracker/README.md||"
"news|news/news-filter/config/keywords.txt|Palabras clave del filtro de noticias|Una por linea. Las elegis vos: temas que te interesen||"
)

# Un archivo esta completo si existe, es archivo (no directorio), tiene
# contenido, y no quedo con los marcadores de la plantilla
archivo_completo() {
    local ruta="$1" marcador="${2:-}"
    [ -f "$ruta" ] || return 1
    [ -s "$ruta" ] || return 1
    [ -n "$marcador" ] && grep -q "$marcador" "$ruta" 2>/dev/null && return 1
    return 0
}

# Crea los archivos que falten, desde su plantilla si la hay.
# Esto evita que Docker los cree como directorios al montarlos.
crear_archivos_faltantes() {
    local linea m ruta desc como plantilla marcador creados=0
    for linea in "${ARCHIVOS[@]}"; do
        IFS='|' read -r m ruta desc como plantilla marcador <<< "$linea"
        [[ " ${SELECCION[*]} " == *" $m "* ]] || continue

        # Si Docker ya lo creo como directorio, hay que sacarlo
        if [ -d "$ruta" ]; then
            rmdir "$ruta" 2>/dev/null || sudo rm -rf "$ruta"
            aviso "$ruta estaba creado como directorio, lo corrijo"
        fi

        if [ ! -e "$ruta" ]; then
            mkdir -p "$(dirname "$ruta")"
            if [ -n "$plantilla" ] && [ -f "$plantilla" ]; then
                cp "$plantilla" "$ruta"
            else
                touch "$ruta"
            fi
            creados=$((creados+1))
        fi
    done
    [ "$creados" -gt 0 ] && ok "Cree $creados archivos vacios, para que Docker no los cree como directorios"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  UTILIDADES
# ══════════════════════════════════════════════════════════════════════════════

preguntar() {
    local q="$1" d="${2:-s}" r sufijo
    [ "$d" = "s" ] && sufijo="[S/n]" || sufijo="[s/N]"
    read -r -p "  ${B}$q${N} $sufijo " r </dev/tty
    r="${r:-$d}"; [[ "$r" =~ ^[SsYy] ]]
}

# Lee el valor de una variable dentro de un archivo .env
leer_var() {
    local archivo="$1" var="$2"
    [ -f "$archivo" ] || return 1
    grep -E "^${var}=" "$archivo" 2>/dev/null | head -1 | cut -d= -f2-
}

# Escribe (o reemplaza) una variable en un archivo .env
escribir_var() {
    local archivo="$1" var="$2" valor="$3"
    mkdir -p "$(dirname "$archivo")"
    touch "$archivo"
    if grep -qE "^${var}=" "$archivo" 2>/dev/null; then
        local tmp; tmp=$(mktemp)
        grep -vE "^${var}=" "$archivo" > "$tmp"
        printf '%s=%s\n' "$var" "$valor" >> "$tmp"
        mv "$tmp" "$archivo"
    else
        printf '%s=%s\n' "$var" "$valor" >> "$archivo"
    fi
}

# Una variable esta "completa" si existe y no esta vacia ni con un placeholder
completa() {
    local valor; valor=$(leer_var "$1" "$2") || return 1
    [ -n "$valor" ] || return 1
    case "$valor" in
        your_*|change*|CHANGE*|generate_with_*|*_here|tu_*) return 1 ;;
        # Las rutas de ejemplo del repo no empiezan con your_ sino con /home/
        # youruser, asi que se colaban. Y como FITBIT_EXPORTS_PATH y
        # FINANCE_DATA_PATH son de tipo auto, el instalador solo las escribe
        # si estan incompletas: dadas por buenas una vez, quedaban para siempre.
        *youruser*|"<"*) return 1 ;;
    esac
    return 0
}

# ── Contrasena unica ──────────────────────────────────────────────────────────
#
#  La primera version de este instalador pedia una contrasena por servicio y
#  terminabas con dos distintas sin darte cuenta: el hash de Caddy con una y
#  los paneles con otra, y despues no entrabas a la homepage. Ahora se pide
#  una sola vez.

pedir_clave_maestra() {
    [ -n "$CLAVE_MAESTRA" ] && return 0

    echo ""
    echo "  ${B}${C}Contrasena${N}"
    info "Una sola contrasena para todo: la homepage, los paneles, y las cuentas"
    info "que voy a crear solo (Jellyfin, qBittorrent, Radarr, Prowlarr, Bazarr,"
    info "Grafana y Pi-hole)."
    echo ""
    gris "     Asi no te pasa lo de terminar con dos contrasenas distintas y no"
    gris "     saber cual va en cada lado."
    echo ""

    local v1 v2
    while true; do
        read -r -s -p "  ${B}Contrasena:${N} " v1 </dev/tty; echo ""
        if [ -z "$v1" ]; then
            aviso "No puede quedar vacia."
            continue
        fi
        read -r -s -p "  ${B}Repetila:${N}   " v2 </dev/tty; echo ""
        [ "$v1" = "$v2" ] && break
        falla "No coinciden, probemos de nuevo."
    done
    CLAVE_MAESTRA="$v1"
    unset v1 v2
    ok "Guardada. La uso en todos los servicios."

    # qBittorrent rechaza contrasenas de menos de 6 caracteres. Es regla suya.
    # Mejor avisarlo ahora que dejar que falle a mitad de la instalacion.
    if [ ${#CLAVE_MAESTRA} -lt 6 ] && [[ " ${SELECCION[*]} " == *" media "* ]]; then
        echo ""
        aviso "qBittorrent no acepta contrasenas de menos de 6 caracteres."
        gris "     Es una regla suya, no mia. El resto de los servicios la toman."
        echo ""
        if preguntar "¿Elegis otra de 6 o mas, y la usamos en todo?" "s"; then
            CLAVE_MAESTRA=""
            pedir_clave_maestra
            return
        fi
        info "Bien: a qBittorrent le pongo una aparte y te la pido cuando llegue."
    fi

    echo ""
    if preguntar "¿Queres una contrasena distinta para algun servicio puntual?" "n"; then
        CLAVE_POR_SERVICIO=1
        info "Bien: te la voy pidiendo servicio por servicio."
        gris "     Enter en cualquiera y usa la general."
    fi
    echo ""
}

# Devuelve la contrasena que corresponde a un servicio. Con la opcion de
# contrasenas separadas activada, la pregunta; si no, devuelve la general.
clave_para() {
    local que="$1" v
    pedir_clave_maestra
    if [ "$CLAVE_POR_SERVICIO" = "1" ]; then
        printf "        ${B}contrasena para %s${N} (Enter para la general): " "$que" > /dev/tty
        read -r -s v </dev/tty; echo "" > /dev/tty
        [ -n "$v" ] && { echo "$v"; return; }
    fi
    echo "$CLAVE_MAESTRA"
}

# ── El DAS ────────────────────────────────────────────────────────────────────
#
#  DAS_ROOT trae /mnt/das por defecto, y esa carpeta existe aunque no haya
#  ningun disco conectado. O sea que el stack multimedia arranca igual, se ve
#  sano, y baja todo a la tarjeta del sistema hasta llenarla. Una tarjeta llena
#  es justo lo que corrompe el sistema de archivos.
#
#  La pregunta correcta no es "existe la carpeta" ni siquiera "es un punto de
#  montaje", sino si esta en OTRO dispositivo que la raiz del sistema.

das_ruta() {
    local r; r=$(leer_var media/.env DAS_ROOT 2>/dev/null)
    echo "${r:-/mnt/das}"
}

das_montado() {
    local raiz dev_das dev_raiz
    raiz=$(das_ruta)
    [ -d "$raiz" ] || return 1
    dev_das=$(df --output=source "$raiz" 2>/dev/null | tail -1)
    dev_raiz=$(df --output=source / 2>/dev/null | tail -1)
    [ -n "$dev_das" ] && [ "$dev_das" != "$dev_raiz" ] || return 1

    # Estar en otro disco no alcanza. Un DAS remontado de solo lectura, que es
    # lo que hace ext4 cuando encuentra errores, pasaria la prueba de arriba y
    # despues nada podria escribir una sola pelicula.
    local prueba="$raiz/.instalador-prueba-escritura"
    if ! touch "$prueba" 2>/dev/null; then
        return 1
    fi
    rm -f "$prueba" 2>/dev/null
    return 0
}

# Por que no esta usable, para poder decirlo en vez de solo negarlo
das_por_que_no() {
    local raiz; raiz=$(das_ruta)
    if [ ! -d "$raiz" ]; then
        echo "la carpeta $raiz no existe"
    elif [ "$(df --output=source "$raiz" 2>/dev/null | tail -1)" = "$(df --output=source / 2>/dev/null | tail -1)" ]; then
        echo "es una carpeta en la misma tarjeta del sistema, no un disco aparte"
    elif ! touch "$raiz/.instalador-prueba-escritura" 2>/dev/null; then
        echo "esta montado pero es de solo lectura"
    else
        rm -f "$raiz/.instalador-prueba-escritura" 2>/dev/null
        echo ""
    fi
}

das_libre() {
    df -h --output=avail "$(das_ruta)" 2>/dev/null | tail -1 | tr -d ' '
}

# Un contenedor esta arriba si esta RUNNING. Sin el filtro, `docker ps` lista
# tambien los que estan en bucle de reinicio, y un servicio que arranca y se
# cae cada diez segundos se contaba como funcionando.
#
# La lista se pide UNA vez y se guarda unos segundos. Antes salia un `docker ps`
# por cada servicio y por cada variable: 44 invocaciones antes de mostrar la
# primera pantalla, casi cinco segundos mirando una terminal vacia. Los tres
# segundos de vida del cache son mas que suficientes para una tanda de
# comprobaciones, y cortos para no dar una respuesta vieja despues de levantar
# algo.
CACHE_CORRIENDO=""
CACHE_MOMENTO=0

esta_arriba() {
    local ahora; ahora=$(date +%s)
    if [ $((ahora - CACHE_MOMENTO)) -ge 3 ]; then
        CACHE_CORRIENDO=" $($DOCKER ps --filter status=running --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"
        CACHE_MOMENTO=$ahora
    fi
    [[ "$CACHE_CORRIENDO" == *" $1 "* ]]
}

# Para llamar despues de levantar o parar algo, y no esperar los tres segundos
olvidar_estado() { CACHE_MOMENTO=0; }

# Cuenta contenedores de un modulo que estan corriendo
corriendo() {
    local mod="$1" n=0 s
    for s in ${SERVICIOS[$mod]:-}; do
        esta_arriba "$s" && n=$((n+1))
    done
    echo "$n"
}

# Cuantos del modulo estan reiniciando en bucle, que no es lo mismo que caidos
reiniciando() {
    local mod="$1" n=0 s
    for s in ${SERVICIOS[$mod]:-}; do
        [ "$($DOCKER inspect -f '{{.State.Status}}' "$s" 2>/dev/null)" = "restarting" ] && n=$((n+1))
    done
    echo "$n"
}

total_servicios() {
    local mod="$1"; echo "${SERVICIOS[$mod]:-}" | wc -w
}

# ══════════════════════════════════════════════════════════════════════════════
#  PUEDE HACER SU TRABAJO?
#
#  Contar contenedores arriba y variables cargadas no alcanza. Prowlarr sin
#  indexers responde perfecto y no encuentra nada; Bazarr sin perfil de idiomas
#  no baja un solo subtitulo; y el stack multimedia sin disco externo descarga
#  a la tarjeta del sistema hasta llenarla. Los tres se reportaban como
#  "funcionando".
#
#  Estos chequeos corren al arrancar el instalador, cada vez, asi que tienen
#  que ser BARATOS: una llamada, sin reintentos, y solo si el contenedor esta
#  arriba. Y conservadores: un aviso que salta sin motivo ensena a ignorarlos.
# ══════════════════════════════════════════════════════════════════════════════

# Cuenta cuantos elementos devuelve un endpoint de los *arr
arr_conteo() {
    esta_arriba "$1" || { echo 0; return; }
    arr_api "$1" "$2" "$3" GET "$4" 2>/dev/null | grep -o '"id"' | wc -l
}

bazarr_sin_perfil() {
    esta_arriba bazarr || return 1
    ! $DOCKER exec bazarr sh -c 'grep -q "enabled_languages" /config/config/config.yaml' 2>/dev/null
}

freshrss_sin_instalar() {
    esta_arriba freshrss || return 1
    ! $DOCKER exec freshrss sh -c 'test -f /var/www/FreshRSS/data/config.php' 2>/dev/null
}

# El bind mount puede apuntar a un directorio que ya no existe: el archivo se
# ve bien desde el host y el contenedor no lo tiene. Falla en silencio.
keywords_invisible() {
    esta_arriba news-filter || return 1
    ! $DOCKER exec news-filter sh -c 'test -s /app/config/keywords.txt' 2>/dev/null
}

# Devuelve por stdout lo que le falta al modulo para poder trabajar, o vacio.
config_pendiente() {
    local mod="$1" faltas=()

    case "$mod" in
        media)
            [ "$(corriendo media)" -gt 0 ] || return 0
            das_montado || faltas+=("sin disco externo, descargaria a la tarjeta")
            [ "$(arr_conteo prowlarr 9696 v1 /indexer)" = "0" ] && faltas+=("Prowlarr sin indexers")
            esta_arriba sonarr && [ "$(arr_conteo sonarr 8989 v3 /rootfolder)" = "0" ] && \
                faltas+=("Sonarr sin carpeta de series")
            bazarr_sin_perfil && faltas+=("Bazarr sin perfil de idiomas")
            ;;
        news)
            [ "$(corriendo news)" -gt 0 ] || return 0
            freshrss_sin_instalar && faltas+=("FreshRSS sin terminar de instalar")
            keywords_invisible && faltas+=("el contenedor no ve keywords.txt")
            ;;
        monitoring)
            esta_arriba prometheus || return 0
            local caidos
            caidos=$($DOCKER exec prometheus sh -c \
                'wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null' 2>/dev/null \
                | grep -o '"health":"down"' | wc -l)
            [ "${caidos:-0}" -gt 0 ] && \
                faltas+=("$caidos $(plural "$caidos" "objetivo" "objetivos") de Prometheus sin responder")
            ;;
    esac

    [ ${#faltas[@]} -eq 0 ] && return 0

    # Como maximo dos, y el resto contado. La linea de estado tiene que
    # entrar en el ancho de una terminal, y el detalle completo lo da el
    # diagnostico, que para eso existe.
    local salida="${faltas[0]}"
    [ ${#faltas[@]} -ge 2 ] && salida="$salida, ${faltas[1]}"
    [ ${#faltas[@]} -gt 2 ] && salida="$salida y $(( ${#faltas[@]} - 2 )) mas"
    echo "$salida"
}

# ══════════════════════════════════════════════════════════════════════════════
#  DETECCION DE ESTADO
# ══════════════════════════════════════════════════════════════════════════════

declare -A ESTADO
declare -A DETALLE

detectar() {
    local mod

    # --- nativos ---
    if command -v docker >/dev/null 2>&1 && systemctl is-enabled log2ram >/dev/null 2>&1; then
        ESTADO[sistema]=activo; DETALLE[sistema]="Docker y log2ram instalados"
    elif command -v docker >/dev/null 2>&1; then
        ESTADO[sistema]=parcial; DETALLE[sistema]="Docker si, falta log2ram"
    else
        ESTADO[sistema]=inactivo; DETALLE[sistema]="falta Docker"
    fi

    if command -v pihole >/dev/null 2>&1 && systemctl is-active pihole-FTL >/dev/null 2>&1; then
        local dominios; dominios=$(sudo pihole-FTL sqlite3 /etc/pihole/gravity.db 'SELECT COUNT(*) FROM gravity;' 2>/dev/null)
        if [ "${dominios:-0}" -gt 1000 ] 2>/dev/null; then
            ESTADO[pihole]=activo; DETALLE[pihole]="$dominios dominios bloqueados"
        else
            ESTADO[pihole]=parcial; DETALLE[pihole]="instalado pero sin listas cargadas"
        fi
    else
        ESTADO[pihole]=inactivo; DETALLE[pihole]="no instalado"
    fi


    if command -v tailscale >/dev/null 2>&1 && sudo tailscale status >/dev/null 2>&1; then
        ESTADO[tailscale]=activo; DETALLE[tailscale]="conectado como $(sudo tailscale ip -4 2>/dev/null | head -1)"
    elif command -v tailscale >/dev/null 2>&1; then
        ESTADO[tailscale]=parcial; DETALLE[tailscale]="instalado pero sin autenticar"
    else
        ESTADO[tailscale]=inactivo; DETALLE[tailscale]="no instalado"
    fi

    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        if systemctl is-active fail2ban >/dev/null 2>&1; then
            ESTADO[seguridad]=activo; DETALLE[seguridad]="UFW y fail2ban activos"
        else
            ESTADO[seguridad]=parcial; DETALLE[seguridad]="UFW si, fail2ban no"
        fi
    else
        ESTADO[seguridad]=inactivo; DETALLE[seguridad]="firewall desactivado"
    fi

    # --- modulos de Docker ---
    for mod in "${!SERVICIOS[@]}"; do
        local arriba total faltan var linea m arch v tipo
        arriba=$(corriendo "$mod"); total=$(total_servicios "$mod")

        faltan=0
        for linea in "${VARIABLES[@]}"; do
            IFS='|' read -r m arch v tipo _ _ <<< "$linea"
            [ "$m" = "$mod" ] || continue
            [ "$tipo" = "auto" ] && continue
            completa "$arch" "$v" || faltan=$((faltan+1))
        done
        # Los archivos (tokens de OAuth, listas) cuentan igual que las variables:
        # sin ellos el servicio corre pero no puede hacer nada
        local ruta marcador
        for linea in "${ARCHIVOS[@]}"; do
            IFS='|' read -r m ruta _ _ _ marcador <<< "$linea"
            [ "$m" = "$mod" ] || continue
            archivo_completo "$ruta" "$marcador" || faltan=$((faltan+1))
        done

        # Y lo que no se ve en las variables: si el servicio puede trabajar
        local pendiente_cfg; pendiente_cfg=$(config_pendiente "$mod")

        # Reiniciar en bucle no es estar arriba ni estar caido: es su propia cosa
        local en_bucle; en_bucle=$(reiniciando "$mod")

        local datos; datos=$(plural "$faltan" "dato" "datos")
        local cont;  cont=$(plural "$total" "contenedor" "contenedores")

        if [ "$en_bucle" -gt 0 ]; then
            ESTADO[$mod]=parcial
            DETALLE[$mod]="$en_bucle $(plural "$en_bucle" "contenedor reinicia" "contenedores reinician") en bucle"
        elif [ "$arriba" -eq "$total" ] && [ "$faltan" -eq 0 ] && [ -z "$pendiente_cfg" ]; then
            ESTADO[$mod]=activo; DETALLE[$mod]="$arriba de $total $cont arriba"
        elif [ "$arriba" -eq "$total" ] && [ -n "$pendiente_cfg" ]; then
            ESTADO[$mod]=parcial; DETALLE[$mod]="arriba, pero $pendiente_cfg"
        elif [ "$arriba" -eq "$total" ] && [ "$faltan" -gt 0 ]; then
            ESTADO[$mod]=parcial; DETALLE[$mod]="$arriba de $total arriba, pero $(plural "$faltan" "falta" "faltan") $faltan $datos"
        elif [ "$arriba" -gt 0 ]; then
            ESTADO[$mod]=parcial; DETALLE[$mod]="solo $arriba de $total $cont arriba"
        else
            ESTADO[$mod]=inactivo
            [ "$faltan" -gt 0 ] && DETALLE[$mod]="sin levantar, $(plural "$faltan" "falta" "faltan") $faltan $datos" || DETALLE[$mod]="sin levantar"
        fi
    done
}

icono() {
    case "$1" in
        activo)   echo "${V}●${N}" ;;
        parcial)  echo "${A}◐${N}" ;;
        *)        echo "${G}○${N}" ;;
    esac
}

etiqueta() {
    case "$1" in
        activo)   echo "${V}funcionando${N}" ;;
        parcial)  echo "${A}incompleto${N}" ;;
        *)        echo "${G}sin instalar${N}" ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
#  CONFIGURACION AUTOMATICA
#
#  Todo lo que antes te tocaba hacer a mano en el navegador y se puede hacer
#  por API o por linea de comandos. Dos reglas:
#
#    1. Idempotente. Si algo ya esta configurado, lo deja como esta.
#    2. Nunca deja un servicio peor de como lo encontro. Si un paso falla,
#       avisa y lo pasa a la lista de pendientes en vez de romper.
#
#  Las llamadas HTTP salen desde ADENTRO de cada contenedor contra su propio
#  localhost, porque ninguno publica su puerto al host. Todos traen curl.
# ══════════════════════════════════════════════════════════════════════════════


# Recien levantado un contenedor puede tardar en atender. Esperamos.
#
# Importa mirar el codigo y no solo si curl anduvo: Jellyfin contesta 503 un
# buen rato mientras arranca, y curl devuelve exito igual. Dar eso por listo
# hace que todo lo que venga despues falle sin motivo aparente.
esperar_http() {
    local svc="$1" puerto="$2" ruta="${3:-/}" i code
    for i in $(seq 1 45); do
        esta_arriba "$svc" || return 1
        code=$($DOCKER exec "$svc" curl -s -o /dev/null -w '%{http_code}' --max-time 4 \
            "http://localhost:$puerto$ruta" 2>/dev/null)
        case "$code" in
            ""|000|5*) ;;   # sin respuesta o todavia arrancando
            *) return 0 ;;
        esac
        sleep 2
    done
    return 1
}

# ── Radarr y Prowlarr ─────────────────────────────────────────────────────────

# Su API key se autogenera en config.xml en el primer arranque
api_key_arr() {
    $DOCKER exec "$1" sh -c 'grep -oE "<ApiKey>[^<]*" /config/config.xml' 2>/dev/null | cut -d'>' -f2
}

arr_api() {
    local svc="$1" puerto="$2" ver="$3" metodo="$4" ruta="$5" cuerpo="${6:-}" k
    k=$(api_key_arr "$svc")
    [ -n "$k" ] || return 1
    if [ -n "$cuerpo" ]; then
        $DOCKER exec -i "$svc" curl -s -X "$metodo" -H "X-Api-Key: $k" \
            -H "Content-Type: application/json" -d @- \
            "http://localhost:$puerto/api/$ver$ruta" <<< "$cuerpo"
    else
        $DOCKER exec "$svc" curl -s -X "$metodo" -H "X-Api-Key: $k" \
            "http://localhost:$puerto/api/$ver$ruta"
    fi
}

# Radarr, Prowlarr y Bazarr salen de fabrica SIN contrasena, y Caddy tampoco
# les pone una porque se asume que traen la propia. O sea que quedan abiertos
# a cualquiera en tu red. Esto lo cierra.
arr_autenticacion() {
    local svc="$1" puerto="$2" ver="$3" clave="$4" actual nuevo id
    actual=$(arr_api "$svc" "$puerto" "$ver" GET /config/host 2>/dev/null | python3 -c \
        'import sys,json;print(json.load(sys.stdin).get("authenticationMethod",""))' 2>/dev/null)
    case "$actual" in
        forms|basic)
            # Ya tiene una. Como la API key nos deja cambiarla sin saber la
            # vieja, se puede ofrecer unificarla en vez de dejarte con dos.
            if ! unificar_claves; then
                gris "     $svc queda con la contrasena que ya tenia"
                return 0
            fi
            ;;
        "") aviso "$svc: no pude leer su configuracion"; return 1 ;;
    esac
    nuevo=$(arr_api "$svc" "$puerto" "$ver" GET /config/host 2>/dev/null | CLAVE="$clave" python3 -c '
import sys, json, os
d = json.load(sys.stdin)
d["authenticationMethod"] = "forms"
d["authenticationRequired"] = "enabled"
d["username"] = "admin"
d["password"] = os.environ["CLAVE"]
d["passwordConfirmation"] = os.environ["CLAVE"]
print(json.dumps(d))' 2>/dev/null)
    [ -n "$nuevo" ] || { aviso "$svc: no pude armar la configuracion"; return 1; }
    id=$(echo "$nuevo" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",1))' 2>/dev/null)
    arr_api "$svc" "$puerto" "$ver" PUT "/config/host/$id" "$nuevo" >/dev/null 2>&1
    ok "$svc: usuario ${B}admin${N} con tu contrasena"
    [ "$actual" = "none" ] && gris "     antes se entraba sin ninguna"
    return 0
}

# Radarr y Sonarr son el mismo motor con distinto contenido: misma API, mismos
# endpoints, misma forma de configurarse. Lo unico que cambia son el puerto, la
# carpeta y como llama a su categoria de descargas.
#
# Por eso va una sola funcion y no dos copias. Con dos, cualquier arreglo hay
# que acordarse de hacerlo dos veces, y el dia que uno se olvida queda un bug
# que solo aparece en las series, o solo en las peliculas.
#
#   $1 servicio   $2 puerto   $3 nombre visible   $4 carpeta   $5 prefijo de campos   $6 contrasena
cfg_arr() {
    local svc="$1" puerto="$2" nombre="$3" carpeta="$4" pref="$5" clave="$6"
    local resp cuerpo

    esperar_http "$svc" "$puerto" /api/v3/system/status || {
        aviso "$nombre no contesta"
        pendiente "Configurar $nombre: no contestaba al instalar. Volve a correr el instalador"
        return 1
    }

    # ── Carpeta raiz ──
    if arr_api "$svc" "$puerto" v3 GET /rootfolder 2>/dev/null | grep -q "$carpeta"; then
        gris "     carpeta raiz ya cargada"
    else
        # Tiene que existir antes: los *arr rechazan una carpeta inexistente.
        mkdir -p "$(das_ruta)/media/$(basename "$carpeta")" 2>/dev/null
        resp=$(arr_api "$svc" "$puerto" v3 POST /rootfolder "{\"path\":\"$carpeta\"}" 2>/dev/null)
        if echo "$resp" | grep -q '"errorMessage"'; then
            gris "     carpeta raiz: $(echo "$resp" | python3 -c                 'import sys,json;print(json.load(sys.stdin)[0].get("errorMessage",""))' 2>/dev/null)"
        else
            ok "$nombre: carpeta raiz ${B}$carpeta${N}"
        fi
    fi

    # ── Hardlinks: sin esto cada archivo ocupa el doble ──
    local mm
    mm=$(arr_api "$svc" "$puerto" v3 GET /config/mediamanagement 2>/dev/null)
    if [ "$(echo "$mm" | python3 -c         'import sys,json;print(json.load(sys.stdin).get("copyUsingHardlinks"))' 2>/dev/null)" = "True" ]; then
        gris "     hardlinks ya activados"
    elif [ -n "$mm" ]; then
        local mm2 mmid
        mm2=$(echo "$mm" | python3 -c 'import sys,json;d=json.load(sys.stdin);d["copyUsingHardlinks"]=True;print(json.dumps(d))' 2>/dev/null)
        mmid=$(echo "$mm" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",1))' 2>/dev/null)
        arr_api "$svc" "$puerto" v3 PUT "/config/mediamanagement/$mmid" "$mm2" >/dev/null 2>&1
        ok "$nombre: hardlinks activados"
    fi

    # ── Cliente de descargas ──
    if arr_api "$svc" "$puerto" v3 GET /downloadclient 2>/dev/null | grep -qi 'qbittorrent'; then
        gris "     qBittorrent ya estaba conectado"
    elif esta_arriba qbittorrent; then
        # Con la contrasena real de qBittorrent, que puede no ser la general.
        # Valida la conexion al guardar: si no puede entrar, no guarda nada.
        cuerpo=$(CLAVE="${CLAVE_QBIT:-$clave}" PREF="$pref" CAT="$svc" python3 -c '
import json, os
p = os.environ["PREF"]
print(json.dumps({
  "enable": True, "protocol": "torrent", "priority": 1,
  "removeCompletedDownloads": True, "removeFailedDownloads": True,
  "name": "qBittorrent", "implementation": "QBittorrent",
  "implementationName": "qBittorrent", "configContract": "QBittorrentSettings",
  "fields": [
    {"name": "host", "value": "qbittorrent"},
    {"name": "port", "value": 8080},
    {"name": "useSsl", "value": False},
    {"name": "username", "value": "admin"},
    {"name": "password", "value": os.environ["CLAVE"]},
    {"name": p + "Category", "value": os.environ["CAT"]},
    {"name": "contentLayout", "value": 0},
    {"name": "initialState", "value": 0},
    {"name": "recent" + p.capitalize() + "Priority", "value": 0},
    {"name": "older" + p.capitalize() + "Priority", "value": 0},
    {"name": "sequentialOrder", "value": False},
    {"name": "firstAndLast", "value": False}
  ], "tags": []}))' 2>/dev/null)
        resp=$(arr_api "$svc" "$puerto" v3 POST /downloadclient "$cuerpo" 2>/dev/null)
        if echo "$resp" | grep -q '"errorMessage"'; then
            aviso "$nombre: no pudo conectarse a qBittorrent"
            gris "     $(echo "$resp" | python3 -c                 'import sys,json;print(json.load(sys.stdin)[0].get("errorMessage",""))' 2>/dev/null)"
            pendiente "Conectar qBittorrent en http://$svc.pi, Settings, Download Clients"
        else
            ok "$nombre: qBittorrent conectado como cliente de descargas"
        fi
    fi

    arr_autenticacion "$svc" "$puerto" v3 "$clave"
}

cfg_radarr() { cfg_arr radarr 7878 Radarr /data/media/movies movie "$1"; }
cfg_sonarr() { cfg_arr sonarr 8989 Sonarr /data/media/tv     tv    "$1"; }

cfg_prowlarr() {
    local clave="$1"
    esperar_http prowlarr 9696 /api/v1/system/status || {
        aviso "Prowlarr no contesta"
        pendiente "Configurar Prowlarr: no contestaba al instalar. Volve a correr el instalador"
        return 1
    }

    # Se enlaza con los dos por el mismo camino. Prowlarr no distingue entre
    # peliculas y series: para el son dos aplicaciones que quieren indexers.
    enlazar_con_prowlarr radarr 7878 Radarr
    enlazar_con_prowlarr sonarr 8989 Sonarr

    arr_autenticacion prowlarr 9696 v1 "$clave"
}

# Le da a Prowlarr una aplicacion a la que sincronizarle los indexers.
enlazar_con_prowlarr() {
    local svc="$1" puerto="$2" nombre="$3" k cuerpo
    esta_arriba "$svc" || return 0

    if arr_api prowlarr 9696 v1 GET /applications 2>/dev/null | grep -qi "\"name\": *\"$nombre\""; then
        gris "     $nombre ya estaba enlazado"
        return 0
    fi

    k=$(api_key_arr "$svc")
    [ -n "$k" ] || return 0

    cuerpo=$(K="$k" NOMBRE="$nombre" URL="http://$svc:$puerto" python3 -c '
import json, os
print(json.dumps({
  "name": os.environ["NOMBRE"], "implementation": os.environ["NOMBRE"],
  "implementationName": os.environ["NOMBRE"],
  "configContract": os.environ["NOMBRE"] + "Settings",
  "syncLevel": "fullSync",
  "fields": [
    {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
    {"name": "baseUrl", "value": os.environ["URL"]},
    {"name": "apiKey", "value": os.environ["K"]}
  ], "tags": []}))' 2>/dev/null)

    arr_api prowlarr 9696 v1 POST /applications "$cuerpo" >/dev/null 2>&1
    ok "Prowlarr: enlazado con $nombre"
    gris "     los indexers que cargues se le sincronizan solos"
}

# ── Sin DAS, las descargas van a la tarjeta ───────────────────────────────────

# pausa = configurar todo pero sin bajar nada  ·  igual = bajar igual  ·  no = no tocar
MEDIA_MODO="igual"

decidir_das() {
    if das_montado; then
        ok "DAS montado en $(das_ruta), $(das_libre) libres"
        MEDIA_MODO="igual"
        return 0
    fi

    local raiz motivo
    raiz=$(das_ruta)
    motivo=$(das_por_que_no)
    echo ""
    aviso "${B}El disco externo no esta usable.${N}"
    info "DAS_ROOT apunta a ${B}$raiz${N}, y ${motivo:-no se puede escribir ahi}."
    info "Quedan ${B}$(das_libre)${N} libres donde iria todo."
    echo ""
    info "Eso significa que si cargas un indexer y agregas una pelicula, la"
    info "cadena entera funciona y el archivo termina en la tarjeta. Dos o tres"
    info "peliculas la llenan, y una tarjeta llena es lo que corrompe el sistema."
    echo ""
    info "Ademas se pierden los hardlinks: cada pelicula ocuparia el doble,"
    info "una vez en descargas y otra en la biblioteca."
    echo ""
    echo "     ${B}1${N})  configurar todo, pero con las descargas ${B}en pausa${N}   ${G}(recomendado)${N}"
    gris "         queda listo para cuando conectes el disco, y mientras tanto"
    gris "         nada baja solo. Se despausa desde qbit.pi cuando quieras."
    echo "     ${B}2${N})  configurar todo y bajar igual"
    gris "         solo si sabes lo que estas haciendo y vas a mirar el espacio"
    echo "     ${B}3${N})  no tocar multimedia hasta que tengas el disco"
    echo ""

    local r
    read -r -p "     ${B}Que hago${N} [1/2/3]: " r </dev/tty 2>/dev/null || r=1
    case "$r" in
        2) MEDIA_MODO="igual"
           aviso "Bajando a la tarjeta. Vigila el espacio con: df -h /"
           pendiente "Conectar el DAS: las descargas estan yendo a la tarjeta" ;;
        3) MEDIA_MODO="no"
           info "Multimedia queda sin configurar"
           pendiente "Montar el DAS y volver a correr el instalador para multimedia" ;;
        *) MEDIA_MODO="pausa"
           ok "Configuro todo, con las descargas en pausa"
           pendiente "Montar el DAS (ver media/DAS.md) y despausar en http://qbit.pi" ;;
    esac
    echo ""
    return 0
}

# La decision del disco va ANTES de levantar nada. Preguntada despues, la
# opcion de "no tocar multimedia" llega tarde: los cinco contenedores ya
# estan arriba, y qBittorrent ya puede escribir en la tarjeta.
decidir_das_temprano() {
    [[ " ${SELECCION[*]} " == *" media "* ]] || return 0
    decidir_das
    [ "$MEDIA_MODO" = "no" ] || return 0

    local m nueva=()
    for m in "${SELECCION[@]}"; do
        [ "$m" = "media" ] || nueva+=("$m")
    done
    SELECCION=("${nueva[@]}")
    info "Saco multimedia de la lista: no levanto ninguno de sus contenedores."
    echo ""
}

# ── Recuperar una credencial que ya existe ────────────────────────────────────
#
#  Un servicio que ya tiene contrasena no se puede reconfigurar a ciegas. Y
#  probar candidatas es peor que no hacer nada: Jellyfin BLOQUEA la cuenta a
#  los pocos intentos fallidos y qBittorrent BANEA la IP. Asi que nunca se
#  adivina: o la sabes, o se resetea a proposito, o se deja como esta.

# Radarr, Prowlarr, Bazarr, Grafana y Pi-hole se manejan por API o por linea de
# comandos, asi que su contrasena se puede cambiar SIN saber la vieja. Si ya
# tenian una, se pregunta una sola vez si unificarlas todas.
UNIFICAR=""

unificar_claves() {
    if [ -z "$UNIFICAR" ]; then
        echo ""
        aviso "Algunos servicios ya tenian contrasena puesta de antes."
        gris "     A estos los manejo por API, asi que puedo ponerles la nueva"
        gris "     sin necesidad de saber la vieja."
        echo ""
        if preguntar "¿Les pongo la contrasena nueva y queda una sola para todo?" "s"; then
            UNIFICAR=si
        else
            UNIFICAR=no
            info "Los dejo con la que tenian."
        fi
        echo ""
    fi
    [ "$UNIFICAR" = "si" ]
}

# Donde vive el /config de un contenedor, en el host
ruta_config() {
    $DOCKER inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$1" 2>/dev/null
}

# Devuelve por stdout: la contrasena que escribas, "RESET", o vacio para dejarlo.
# Los mensajes van a /dev/tty para no ensuciar lo que devuelve.
menu_credencial() {
    local svc="$1" v=""
    {
        echo ""
        echo "        ${A}!${N} ${B}$svc${N} ya tiene una contrasena distinta a la que elegiste."
        echo "          No la puedo adivinar: probar de a una bloquea la cuenta."
        echo ""
        echo "          ${B}1${N})  la escribo yo"
        echo "          ${B}2${N})  resetearla y ponerle la nueva"
        echo "          ${B}3${N})  dejarlo como esta"
        echo ""
        printf "          ${B}que hago${N} [1/2/3]: "
    } > /dev/tty 2>/dev/null
    read -r v < /dev/tty 2>/dev/null || v=3
    case "$v" in
        1)
            printf "          ${B}contrasena actual:${N} " > /dev/tty 2>/dev/null
            v=""
            read -r -s v < /dev/tty 2>/dev/null || true
            echo "" > /dev/tty 2>/dev/null
            echo "$v"
            ;;
        2) echo "RESET" ;;
        *) echo "" ;;
    esac
}

# ── qBittorrent ───────────────────────────────────────────────────────────────

# La contrasena con la que qBittorrent quedo realmente. Puede no ser la general
# si la general tiene menos de 6 caracteres. Radarr la necesita para conectarse.
CLAVE_QBIT=""

# Un solo intento de login. La 5.x contesta 204 sin cuerpo, las viejas 200 con
# "Ok.": verificar contra el texto da falso negativo con un login que anduvo.
qbit_login() {
    local pass="$1" ck="$2" code
    [ -n "$pass" ] || return 1
    code=$($DOCKER exec qbittorrent curl -s -o /dev/null -w '%{http_code}' -c "$ck" -X POST \
        -H "Referer: http://localhost:8080" \
        --data-urlencode "username=admin" --data-urlencode "password=$pass" \
        "http://localhost:8080/api/v2/auth/login" 2>/dev/null)
    [ "$code" = "200" ] || [ "$code" = "204" ]
}

# Su propia configuracion dice si hay contrasena, sin tener que probar ninguna
qbit_tiene_clave() {
    $DOCKER exec qbittorrent sh -c \
        'grep -q "Password_PBKDF2" /config/qBittorrent/qBittorrent.conf' 2>/dev/null
}

qbit_clave_temporal() {
    $DOCKER logs qbittorrent 2>&1 \
        | grep -oE "temporary password is provided for this session: [^ ]+" \
        | tail -1 | awk '{print $NF}'
}

# Vuelve a dejarlo sin contrasena, para poder ponerle una nueva
qbit_resetear() {
    local cfg
    cfg=$(ruta_config qbittorrent)
    # El test va con sudo: los volumenes viven en /var/lib/docker/volumes, que
    # es solo de root, y sin sudo un archivo que existe se ve como inexistente.
    if [ -z "$cfg" ] || ! sudo test -f "$cfg/qBittorrent/qBittorrent.conf"; then
        aviso "No encontre la configuracion de qBittorrent"
        gris "     buscaba en: ${cfg:-(ruta vacia)}"
        return 1
    fi
    info "Lo paro, le saco la contrasena y lo vuelvo a levantar."
    gris "     Hay que pararlo si o si: andando, reescribe su configuracion al salir"
    gris "     y pisa cualquier cambio hecho desde afuera."
    $DOCKER stop qbittorrent >/dev/null 2>&1
    sudo cp "$cfg/qBittorrent/qBittorrent.conf" "$cfg/qBittorrent/qBittorrent.conf.previo" 2>/dev/null
    sudo sed -i '/Password_PBKDF2/d' "$cfg/qBittorrent/qBittorrent.conf"
    $DOCKER start qbittorrent >/dev/null 2>&1
    if ! esperar_http qbittorrent 8080; then
        aviso "qBittorrent no volvio a levantar"
        return 1
    fi
    sleep 4
    ok "qBittorrent reseteado, respaldo en qBittorrent.conf.previo"
    return 0
}

cfg_qbittorrent() {
    local clave="$1" ck=/tmp/instalador.cookie tmp entro=0 prefs resp
    esperar_http qbittorrent 8080 || { aviso "qBittorrent no contesta"; pendiente "Configurar qBittorrent: no contestaba al instalar. Volve a correr el instalador"; return 1; }

    # Minimo 6 caracteres, impuesto por qBittorrent.
    # El contador corta el bucle si no hay terminal donde preguntar: sin el,
    # un read que falla deja la variable como estaba y esto gira para siempre.
    local intentos=0
    while [ ${#clave} -lt 6 ]; do
        intentos=$((intentos+1))
        if [ "$intentos" -gt 3 ]; then clave=""; fi
        if [ -n "$clave" ]; then
            echo ""
            aviso "qBittorrent exige 6 caracteres o mas, y esa tiene ${#clave}."
            printf "        ${B}contrasena solo para qBittorrent:${N} " > /dev/tty 2>/dev/null
            clave=""
            read -r -s clave < /dev/tty 2>/dev/null || true
            echo "" > /dev/tty 2>/dev/null
        fi
        if [ -z "$clave" ]; then
            aviso "qBittorrent se queda con su contrasena temporal"
            gris "     esa cambia en cada reinicio, asi que conviene ponerle una"
            pendiente "Poner contrasena a qBittorrent en http://qbit.pi"
            return 1
        fi
    done

    $DOCKER exec qbittorrent sh -c "rm -f $ck" 2>/dev/null

    # No se adivina. La conf dice si hay contrasena puesta o no, y eso decide
    # todo: sin ella, la temporal del log es la buena; con ella, hay que
    # preguntar. Probar candidatas hace que qBittorrent banee la IP.
    if qbit_tiene_clave; then
        qbit_login "$clave" "$ck" && entro=1
        if [ "$entro" != "1" ]; then
            local eleccion; eleccion=$(menu_credencial "qBittorrent")
            if [ "$eleccion" = "RESET" ]; then
                qbit_resetear || return 1
                tmp=$(qbit_clave_temporal)
                [ -n "$tmp" ] && qbit_login "$tmp" "$ck" && entro=1
            elif [ -n "$eleccion" ]; then
                qbit_login "$eleccion" "$ck" && entro=1
                [ "$entro" = "1" ] || aviso "Esa contrasena tampoco entra"
            fi
        fi
    else
        tmp=$(qbit_clave_temporal)
        [ -n "$tmp" ] && qbit_login "$tmp" "$ck" && entro=1
    fi

    if [ "$entro" != "1" ]; then
        aviso "qBittorrent: quedo con la contrasena que ya tenia"
        pendiente "Poner contrasena a qBittorrent a mano en http://qbit.pi"
        return 1
    fi

    # save_path viene de fabrica en /downloads, que en este stack NO EXISTE:
    # el DAS se monta en /data. Si no se corrige, las descargas caen dentro
    # del contenedor y encima se pierde el hardlink con la biblioteca.
    # Sin DAS, los torrents entran en pausa: asi Radarr puede mandarlos y no
    # se baja un solo byte a la tarjeta hasta que conectes el disco.
    #
    # Van las DOS claves a proposito: la 4.x la llamaba start_paused_enabled y
    # la 5.x la renombro a add_stopped_enabled. Mandar solo una hacia que la
    # pausa no se aplicara en la version instalada, y como la API contesta
    # vacio igual, el instalador anunciaba una proteccion que no existia.
    local pausar="False"
    [ "$MEDIA_MODO" = "pausa" ] && pausar="True"
    prefs=$(CLAVE="$clave" PAUSA="$pausar" python3 -c '
import json, os
p = os.environ["PAUSA"] == "True"
print(json.dumps({
  "web_ui_username": "admin",
  "web_ui_password": os.environ["CLAVE"],
  "save_path": "/data/downloads/complete",
  "temp_path_enabled": True,
  "temp_path": "/data/downloads/incomplete",
  "create_subfolder_enabled": False,
  "start_paused_enabled": p,
  "add_stopped_enabled": p}))' 2>/dev/null)

    resp=$($DOCKER exec qbittorrent curl -s -b "$ck" -X POST \
        -H "Referer: http://localhost:8080" \
        --data-urlencode "json=$prefs" \
        "http://localhost:8080/api/v2/app/setPreferences" 2>/dev/null)

    if [ -n "$resp" ]; then
        $DOCKER exec qbittorrent sh -c "rm -f $ck" 2>/dev/null
        aviso "qBittorrent: $resp"
        pendiente "Revisar la contrasena de qBittorrent en http://qbit.pi"
        return 1
    fi

    # Leer de vuelta, no confiar en que la respuesta venga vacia. qBittorrent
    # ignora en silencio las preferencias que no conoce, asi que una clave con
    # el nombre de otra version se acepta sin quejarse y no hace nada.
    local aplicado
    aplicado=$($DOCKER exec qbittorrent curl -s -b "$ck" \
        "http://localhost:8080/api/v2/app/preferences" 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(d.get("save_path", ""), d.get("add_stopped_enabled", d.get("start_paused_enabled")))' 2>/dev/null)
    $DOCKER exec qbittorrent sh -c "rm -f $ck" 2>/dev/null

    CLAVE_QBIT="$clave"
    ok "qBittorrent: contrasena puesta y descargas en ${B}/data/downloads${N}"
    gris "     venia apuntando a /downloads, que en este stack no existe"

    if [ "$MEDIA_MODO" = "pausa" ]; then
        if [[ "$aplicado" == *True* ]]; then
            ok "qBittorrent: los torrents entran en pausa"
        else
            aviso "qBittorrent: no pude dejar las descargas en pausa"
            gris "     sin eso, lo que Radarr mande se baja a la tarjeta"
            pendiente "Pausar a mano en http://qbit.pi, Opciones, Descargas, 'No iniciar al agregar'"
        fi
    fi
}

# ── Jellyfin ──────────────────────────────────────────────────────────────────

JF_TOKEN=""

jf_api() {
    local metodo="$1" ruta="$2" cuerpo="${3:-}" auth
    auth="MediaBrowser Client=\"instalador\", Device=\"pi\", DeviceId=\"instalador-pi\", Version=\"1.0.0\""
    [ -n "$JF_TOKEN" ] && auth="$auth, Token=\"$JF_TOKEN\""
    if [ -n "$cuerpo" ]; then
        $DOCKER exec -i jellyfin curl -s -X "$metodo" -H "Content-Type: application/json" \
            -H "Authorization: $auth" -d @- "http://localhost:8096$ruta" <<< "$cuerpo"
    else
        $DOCKER exec jellyfin curl -s -X "$metodo" -H "Content-Type: application/json" \
            -H "Authorization: $auth" "http://localhost:8096$ruta"
    fi
}

# Lo deja sin contrasena para poder ponerle una nueva.
#
# Limpiar el contador de intentos fallidos no es opcional: Jellyfin bloquea la
# cuenta a los pocos fallos y despues devuelve 401 hasta con la contrasena
# correcta. Sin esto, resetear la contrasena no alcanza y el sintoma es
# indistinguible de una contrasena equivocada.
jf_resetear() {
    local nueva="$1" cfg resp uid
    cfg=$(ruta_config jellyfin)
    # Con sudo, por lo mismo que en qBittorrent: la ruta es solo de root
    if [ -z "$cfg" ] || ! sudo test -f "$cfg/data/jellyfin.db"; then
        aviso "No encontre la base de datos de Jellyfin"
        gris "     buscaba en: ${cfg:-(ruta vacia)}"
        return 1
    fi

    info "Lo paro, le saco la contrasena y le limpio el contador de intentos."
    $DOCKER stop jellyfin >/dev/null 2>&1
    sudo cp "$cfg/data/jellyfin.db" "$cfg/data/jellyfin.db.previo" 2>/dev/null
    sudo python3 - "$cfg/data/jellyfin.db" <<'PY' >/dev/null 2>&1
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
cur = c.cursor()
cur.execute("UPDATE Users SET Password = NULL, InvalidLoginAttemptCount = 0, MustUpdatePassword = 0")
cur.execute("UPDATE Permissions SET Value = 0 WHERE Kind = 2")   # Kind 2 = IsDisabled
c.commit()
c.close()
PY
    $DOCKER start jellyfin >/dev/null 2>&1
    if ! esperar_http jellyfin 8096 /System/Info/Public; then
        aviso "Jellyfin no volvio a levantar"
        return 1
    fi

    # Jellyfin contesta 200 en /System/Info/Public antes de estar listo para
    # autenticar, asi que hay que reintentar. Es seguro: la contrasena quedo
    # vacia, o sea que no estamos adivinando nada, y ademas Jellyfin pone el
    # contador de intentos fallidos en cero cuando uno entra bien.
    local i
    JF_TOKEN=""; uid=""
    for i in 1 2 3 4 5 6 7 8; do
        sleep 4
        resp=$(jf_api POST /Users/AuthenticateByName '{"Username":"admin","Pw":""}' 2>/dev/null)
        JF_TOKEN=$(echo "$resp" | python3 -c \
            'import sys,json;print(json.load(sys.stdin).get("AccessToken",""))' 2>/dev/null)
        uid=$(echo "$resp" | python3 -c \
            'import sys,json;print(json.load(sys.stdin).get("User",{}).get("Id",""))' 2>/dev/null)
        [ -n "$JF_TOKEN" ] && [ -n "$uid" ] && break
    done

    if [ -z "$JF_TOKEN" ] || [ -z "$uid" ]; then
        aviso "Jellyfin: no pude entrar ni despues de resetear"
        gris "     la base anterior quedo en jellyfin.db.previo"
        return 1
    fi

    jf_api POST "/Users/$uid/Password" "$(CLAVE="$nueva" python3 -c \
        'import json,os;print(json.dumps({"CurrentPw":"","NewPw":os.environ["CLAVE"]}))')" >/dev/null 2>&1
    ok "Jellyfin: contrasena reseteada y puesta en la nueva"
    gris "     respaldo de la base en jellyfin.db.previo"
    return 0
}

cfg_jellyfin() {
    local clave="$1" listo resp
    esperar_http jellyfin 8096 /System/Info/Public || { aviso "Jellyfin no contesta"; pendiente "Configurar Jellyfin: no contestaba al instalar. Volve a correr el instalador"; return 1; }

    listo=$(jf_api GET /System/Info/Public 2>/dev/null | python3 -c \
        'import sys,json;print(json.load(sys.stdin).get("StartupWizardCompleted"))' 2>/dev/null)

    if [ "$listo" != "True" ]; then
        jf_api POST /Startup/Configuration \
            '{"UICulture":"es","MetadataCountryCode":"UY","PreferredMetadataLanguage":"es"}' >/dev/null 2>&1
        jf_api POST /Startup/User "$(CLAVE="$clave" python3 -c \
            'import json,os;print(json.dumps({"Name":"admin","Password":os.environ["CLAVE"]}))')" >/dev/null 2>&1
        jf_api POST /Startup/RemoteAccess \
            '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null 2>&1
        jf_api POST /Startup/Complete >/dev/null 2>&1
        ok "Jellyfin: asistente completado, usuario ${B}admin${N}"
    else
        gris "     el asistente ya estaba completo"
    fi

    resp=$(jf_api POST /Users/AuthenticateByName "$(CLAVE="$clave" python3 -c \
        'import json,os;print(json.dumps({"Username":"admin","Pw":os.environ["CLAVE"]}))')" 2>/dev/null)
    JF_TOKEN=$(echo "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("AccessToken",""))' 2>/dev/null)

    # Un solo intento. Si no entro, se pregunta: Jellyfin bloquea la cuenta a
    # los pocos intentos fallidos, asi que probar candidatas la deja inservible.
    if [ -z "$JF_TOKEN" ]; then
        local eleccion; eleccion=$(menu_credencial "Jellyfin")
        if [ "$eleccion" = "RESET" ]; then
            jf_resetear "$clave"
        elif [ -n "$eleccion" ]; then
            resp=$(jf_api POST /Users/AuthenticateByName "$(CLAVE="$eleccion" python3 -c \
                'import json,os;print(json.dumps({"Username":"admin","Pw":os.environ["CLAVE"]}))')" 2>/dev/null)
            JF_TOKEN=$(echo "$resp" | python3 -c \
                'import sys,json;print(json.load(sys.stdin).get("AccessToken",""))' 2>/dev/null)
            [ -n "$JF_TOKEN" ] || aviso "Esa contrasena tampoco entra"
        fi
    fi

    if [ -z "$JF_TOKEN" ]; then
        aviso "Jellyfin: sin entrar, salteo la biblioteca y la aceleracion"
        pendiente "Revisar Jellyfin en http://jellyfin.pi"
        return 1
    fi

    if jf_api GET /Library/VirtualFolders 2>/dev/null | grep -q '/media/movies'; then
        gris "     la biblioteca de peliculas ya existia"
    else
        jf_api POST '/Library/VirtualFolders?name=Peliculas&collectionType=movies&refreshLibrary=true' \
            '{"LibraryOptions":{"PathInfos":[{"Path":"/media/movies"}],"EnableRealtimeMonitor":true}}' >/dev/null 2>&1
        ok "Jellyfin: biblioteca ${B}Peliculas${N} en /media/movies"
    fi

    # La Pi 5 decodifica por hardware pero NO codifica: activamos VAAPI solo
    # para decodificar. Dejar la codificacion por hardware prendida la haria
    # fallar en cada transcodificacion.
    local enc nuevo
    enc=$(jf_api GET /System/Configuration/encoding 2>/dev/null)
    if echo "$enc" | grep -q '"HardwareAccelerationType":"vaapi"'; then
        gris "     la aceleracion por hardware ya estaba activa"
    elif [ -n "$enc" ] && [ -e /dev/dri/renderD128 ]; then
        nuevo=$(echo "$enc" | python3 -c '
import sys, json
d = json.load(sys.stdin)
d["HardwareAccelerationType"] = "vaapi"
d["VaapiDevice"] = "/dev/dri/renderD128"
d["EnableHardwareEncoding"] = False
d["HardwareDecodingCodecs"] = ["h264", "hevc", "vc1"]
print(json.dumps(d))' 2>/dev/null)
        [ -n "$nuevo" ] && jf_api POST /System/Configuration/encoding "$nuevo" >/dev/null 2>&1
        ok "Jellyfin: decodificacion por hardware (VAAPI)"
        gris "     la codificacion queda en CPU: la Pi 5 no tiene codificador"
    fi
}

# ── Bazarr ────────────────────────────────────────────────────────────────────

cfg_bazarr() {
    local clave="$1" kr ks salida code tmpf
    esperar_http bazarr 6767 || { aviso "Bazarr no contesta"; pendiente "Configurar Bazarr: no contestaba al instalar. Volve a correr el instalador"; return 1; }
    kr=$(api_key_arr radarr)
    ks=$(api_key_arr sonarr)

    # Bazarr no se configura por API: su configuracion vive en un YAML. Y su
    # contenedor no trae PyYAML alcanzable, asi que el archivo se edita afuera:
    # se saca, se modifica con el python del sistema, y se vuelve a escribir
    # sobre el mismo archivo para no cambiarle el dueno ni los permisos.
    tmpf=$(mktemp)
    $DOCKER exec bazarr cat /config/config/config.yaml > "$tmpf" 2>/dev/null
    if [ ! -s "$tmpf" ]; then
        aviso "Bazarr: no pude leer su configuracion"
        rm -f "$tmpf"
        return 1
    fi
    cp "$tmpf" "$tmpf.previo"

    # Si ya tiene contrasena, se pisa solo si dijiste que si a unificarlas.
    # Su contrasena vive en el mismo archivo, asi que no hace falta la vieja.
    local forzar=no
    if $DOCKER exec bazarr sh -c 'grep -A3 "^auth:" /config/config/config.yaml | grep -q "type: form"' 2>/dev/null; then
        unificar_claves && forzar=si
    fi

    salida=$(CLAVE="$clave" RADARR_KEY="${kr:-}" SONARR_KEY="${ks:-}" ARCHIVO="$tmpf" FORZAR="$forzar" python3 <<'PY' 2>&1
import os, hashlib, yaml

RUTA = os.environ["ARCHIVO"]
with open(RUTA) as f:
    c = yaml.safe_load(f) or {}
for s in ("general", "radarr", "sonarr", "auth"):
    c.setdefault(s, {})

hecho = []
# Los dos por el mismo camino: Bazarr subtitula peliculas y series igual.
for nombre, puerto, var in (("radarr", 7878, "RADARR_KEY"),
                            ("sonarr", 8989, "SONARR_KEY")):
    key = os.environ.get(var, "")
    if key and c.setdefault(nombre, {}).get("apikey") != key:
        c["general"]["use_" + nombre] = True
        c[nombre].update({"ip": nombre, "port": puerto, "apikey": key,
                          "ssl": False, "base_url": "/"})
        hecho.append(nombre)

# Bazarr guarda la contrasena del panel como md5 en su propio config.yaml
if not c["auth"].get("type") or os.environ.get("FORZAR") == "si":
    c["auth"]["type"] = "form"
    c["auth"]["username"] = "admin"
    c["auth"]["password"] = hashlib.md5(os.environ["CLAVE"].encode()).hexdigest()
    hecho.append("auth")

if hecho:
    with open(RUTA, "w") as f:
        yaml.safe_dump(c, f, default_flow_style=False)
print(",".join(hecho) if hecho else "nada")
PY
)

    case "$salida" in
        nada)
            gris "     Bazarr ya estaba configurado"
            rm -f "$tmpf" "$tmpf.previo"
            return 0 ;;
        *radarr*|*sonarr*|*auth*) : ;;
        *)
            aviso "Bazarr: no pude preparar su configuracion"
            gris "     $salida"
            rm -f "$tmpf" "$tmpf.previo"
            return 1 ;;
    esac

    $DOCKER exec -i bazarr sh -c 'cat > /config/config/config.yaml' < "$tmpf"
    $DOCKER restart bazarr >/dev/null 2>&1
    esperar_http bazarr 6767 >/dev/null 2>&1
    [[ "$salida" == *radarr* ]] && ok "Bazarr: conectado a Radarr"
    [[ "$salida" == *sonarr* ]] && ok "Bazarr: conectado a Sonarr"

    # Si pusimos contrasena, verificamos que se pueda entrar. Un hash mal
    # calculado te dejaria afuera de tu propio Bazarr, asi que si el login
    # no funciona lo dejamos como estaba.
    if [[ "$salida" == *auth* ]]; then
        sleep 3
        code=$($DOCKER exec bazarr curl -s -o /dev/null -w '%{http_code}' -X POST \
            --data-urlencode "username=admin" --data-urlencode "password=$clave" \
            "http://localhost:6767/api/system/account?action=login" 2>/dev/null)
        if [ "$code" = "204" ] || [ "$code" = "200" ]; then
            ok "Bazarr: usuario ${B}admin${N} con tu contrasena"
        else
            # Saco la contrasena y dejo el resto: un hash mal calculado te
            # dejaria afuera de tu propio Bazarr sin forma de entrar.
            local tmp2; tmp2=$(mktemp)
            $DOCKER exec bazarr cat /config/config/config.yaml > "$tmp2" 2>/dev/null
            ARCHIVO="$tmp2" python3 <<'PY' >/dev/null 2>&1
import os, yaml
RUTA = os.environ["ARCHIVO"]
c = yaml.safe_load(open(RUTA)) or {}
previo = c.get("auth", {})
c["auth"] = {"type": None, "username": "", "password": "",
             "apikey": previo.get("apikey", "")}
yaml.safe_dump(c, open(RUTA, "w"), default_flow_style=False)
PY
            $DOCKER exec -i bazarr sh -c 'cat > /config/config/config.yaml' < "$tmp2"
            rm -f "$tmp2"
            $DOCKER restart bazarr >/dev/null 2>&1
            aviso "Bazarr: la contrasena no verifico (HTTP $code), la saque para no dejarte afuera"
            pendiente "Poner contrasena a Bazarr a mano en http://bazarr.pi, Settings, General"
        fi
    fi

    rm -f "$tmpf" "$tmpf.previo"
}

# ── Servicios de fuera del stack multimedia ───────────────────────────────────

cfg_grafana() {
    esperar_http grafana 3000 /api/health || { aviso "Grafana no contesta"; pendiente "Ponerle contrasena a Grafana: no contestaba al instalar"; return 1; }
    if $DOCKER exec grafana grafana cli --homepath /usr/share/grafana \
         admin reset-admin-password "$1" >/dev/null 2>&1; then
        ok "Grafana: contrasena de ${B}admin${N} puesta"
        gris "     ya no te pide cambiarla en el primer login"
    else
        aviso "Grafana: no pude cambiarle la contrasena"
        pendiente "Entrar a http://grafana.pi con admin/admin y cambiarla"
    fi
}

# Pi-hole guarda el hash en su propia configuracion: si esta vacio, no hay
# contrasena y ponerla no pisa nada de nadie.
pihole_tiene_clave() {
    [ -n "$(sudo pihole-FTL --config webserver.api.pwhash 2>/dev/null | tr -d '"')" ]
}

# Grafana recien instalado entra con admin/admin. Un solo intento, que ademas
# es la contrasena publica de fabrica, no una que estemos adivinando.
grafana_de_fabrica() {
    esta_arriba grafana || return 1
    [ "$($DOCKER exec grafana curl -s -o /dev/null -w '%{http_code}' \
        -u "admin:admin" http://localhost:3000/api/org 2>/dev/null)" = "200" ]
}

# Un registro por cada host del Caddyfile, sin listas paralelas que mantener.
# Se llama tambien cuando Pi-hole ya estaba andando: agregar un servicio nuevo
# tiene que alcanzar con volver a correr el instalador.
cargar_registros_dns() {
    local H="[" h n=0
    for h in $(hosts_del_caddyfile); do
        H="$H\"$IP_FIJA $h\","
        n=$((n+1))
    done
    [ "$n" -eq 0 ] && { aviso "No pude leer los nombres del Caddyfile"; return 1; }

    sudo pihole-FTL --config dns.hosts "${H%,}]" >/dev/null 2>&1
    sudo systemctl restart pihole-FTL >/dev/null 2>&1
    sleep 2
    ok "$n registros DNS cargados, uno por cada nombre que sirve Caddy"
}

cfg_pihole() {
    if sudo pihole setpassword "$1" >/dev/null 2>&1; then
        ok "Pi-hole: contrasena del panel puesta"
    else
        aviso "Pi-hole: no pude ponerle contrasena"
        pendiente "Correr:  sudo pihole setpassword"
    fi
}

configurar_servicios() {
    local hay=0 mod
    for mod in media monitoring pihole; do
        [[ " ${SELECCION[*]} " == *" $mod "* ]] && hay=1
    done
    [ "$hay" = "1" ] || return 0

    titulo "Configurando los servicios"

    info "Esto es lo que antes tenias que hacer a mano en el navegador."
    info "Lo que ya este configurado no lo toco."
    echo ""

    # Si no se pidio contrasena en esta corrida es porque no faltaba ningun
    # dato, o sea que ya hay una puesta en todos lados. Pedirla igual, como
    # hacia antes, te obligaba a inventar una nueva y con eso reseteaba las de
    # Pi-hole y Grafana sin preguntarte. Ahora se pregunta primero.
    TOCAR_CLAVES=1
    if [ -z "$CLAVE_MAESTRA" ]; then
        info "Los servicios ya tienen contrasena puesta."
        echo ""
        if preguntar "¿Queres cambiarlas?" "n"; then
            pedir_clave_maestra
        else
            TOCAR_CLAVES=0
            info "Las dejo como estan. Configuro solo lo que no son credenciales."
            echo ""
        fi
    fi

    local elegidos_media; elegidos_media=$(servicios_elegidos media)

    # Pi-hole y Grafana se cambian sin saber la vieja, asi que pasan por la
    # misma pregunta que protege a Radarr, Prowlarr y Bazarr. Antes eran los
    # dos unicos que pisaban una credencial existente sin avisar.
    if [ "$TOCAR_CLAVES" = "1" ]; then
        if [[ " ${SELECCION[*]} " == *" pihole "* ]]; then
            if pihole_tiene_clave && ! unificar_claves; then
                gris "     Pi-hole queda con la contrasena que ya tenia"
            else
                cfg_pihole "$(clave_para 'Pi-hole')"
            fi
        fi
        if [[ " ${SELECCION[*]} " == *" monitoring "* ]] && esta_arriba grafana; then
            if ! grafana_de_fabrica && ! unificar_claves; then
                gris "     Grafana queda con la contrasena que ya tenia"
            else
                cfg_grafana "$(clave_para 'Grafana')"
            fi
        fi
    fi

    if [[ " ${SELECCION[*]} " == *" media "* ]] && [ "$MEDIA_MODO" != "no" ]; then
        # El orden importa y sigue el flujo de los datos: qBittorrent primero,
        # porque Radarr y Sonarr necesitan su contrasena para conectarse.
        # Despues los dos *arr, porque Prowlarr y Bazarr se enganchan contra
        # ellos y necesitan sus API keys.
        esta_arriba qbittorrent && [[ " $elegidos_media " == *" qbittorrent "* ]] && \
            cfg_qbittorrent "$(clave_para 'qBittorrent')"
        esta_arriba radarr && [[ " $elegidos_media " == *" radarr "* ]] && \
            cfg_radarr "$(clave_para 'Radarr')"
        esta_arriba sonarr && [[ " $elegidos_media " == *" sonarr "* ]] && \
            cfg_sonarr "$(clave_para 'Sonarr')"
        esta_arriba prowlarr && [[ " $elegidos_media " == *" prowlarr "* ]] && \
            cfg_prowlarr "$(clave_para 'Prowlarr')"
        esta_arriba bazarr && [[ " $elegidos_media " == *" bazarr "* ]] && \
            cfg_bazarr "$(clave_para 'Bazarr')"
        esta_arriba jellyfin && [[ " $elegidos_media " == *" jellyfin "* ]] && \
            cfg_jellyfin "$(clave_para 'Jellyfin')"

        if [ "$MEDIA_MODO" = "pausa" ]; then
            echo ""
            aviso "Las descargas quedaron ${B}en pausa${N} a proposito."
            gris "     Podes cargar indexers y agregar peliculas sin riesgo: se van a"
            gris "     encolar, pero no se baja nada hasta que conectes el disco y las"
            gris "     despauses desde http://qbit.pi."
        fi
    fi
}

