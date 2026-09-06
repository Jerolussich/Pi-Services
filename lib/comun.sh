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

# Las cuatro salidas de un hallazgo, y los ajustes de ajustes.conf.
#
# Va aparte y no aca adentro porque respaldo.sh y avisos.sh tambien necesitan
# avisar, y no tiene sentido que carguen las 2600 lineas de este archivo para
# mandar una notificacion.
# shellcheck source=avisos.sh
. "$REPO/lib/avisos.sh"

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
#
# Se busca por el BLOQUE, no por el nombre del contenedor. Los servicios que
# corren en la red del host (Pi-hole, Home Assistant) se proxean contra una IP
# y no contra un nombre, asi que buscar "reverse_proxy <servicio>:" no los
# encuentra nunca. Buscando el bloque http://<servicio>.pi y sacando el puerto
# de su linea, andan las dos formas.
puerto_de() {
    [ "$1" = "caddy" ] && { echo 80; return; }
    local p
    p=$(awk -v svc="$1" '
        $0 ~ "^http://" svc "\\.pi[ \t]*{" { dentro = 1; next }
        dentro && /reverse_proxy/ { print; exit }
        dentro && /^}/ { exit }
    ' "$REPO/caddy/Caddyfile" 2>/dev/null | grep -oE ':[0-9]+' | tr -d ':' | head -1)
    [ -n "$p" ] && { echo "$p"; return; }
    # Por si el nombre del bloque no coincide con el del contenedor
    grep -oE "reverse_proxy +$1:[0-9]+" "$REPO/caddy/Caddyfile" 2>/dev/null \
        | head -1 | grep -oE '[0-9]+$'
}

# Los puertos que Caddy alcanza en el HOST, no en un contenedor.
#
# Son los que necesitan un trato especial en el firewall: abiertos para las
# redes de Docker, para que Caddy llegue, y cerrados para todo lo demas. El
# panel de Pi-hole en el 8181 fue el primero; Home Assistant en el 8123 el
# segundo, y ahi se noto que la lista estaba escrita a mano y solo tenia uno.
#
# Se reconocen porque su destino empieza con un numero: un contenedor se
# nombra (grafana:3000), el host se direcciona (192.168.68.66:8123).
puertos_del_host() {
    grep -oE 'reverse_proxy +[0-9][0-9.]*:[0-9]+' "$REPO/caddy/Caddyfile" 2>/dev/null \
        | grep -oE ':[0-9]+$' | tr -d ':' | sort -un
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

MODULOS=(sistema pihole core monitoring news finance fitbit media home ofelia avisos tailscale seguridad)

declare -A NOMBRE=(
  [sistema]="Base del sistema"
  [pihole]="Pi-hole  ·  DNS y bloqueo de publicidad"
  [core]="Caddy y Homepage  ·  la puerta de entrada"
  [monitoring]="Monitoreo  ·  Grafana y Prometheus"
  [news]="Noticias  ·  FreshRSS, Wallabag y el filtro"
  [finance]="Finanzas  ·  lector de mails del banco"
  [fitbit]="Fitbit  ·  datos de salud"
  [media]="Multimedia  ·  Jellyfin, Seerr, Radarr, Sonarr, Prowlarr, Bazarr"
  [home]="Casa  ·  Home Assistant, domotica"
  [ofelia]="Ofelia  ·  programador de tareas"
  [avisos]="Avisos  ·  notificaciones al celular"
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
  [home]="Automatizar la casa: luces, sensores, enchufes. Descubre solo lo que hay en tu red."
  [ofelia]="Dispara las tareas programadas del resto de los contenedores."
  [avisos]="La Pi te avisa al celular cuando algo se rompe. No instala nada: crea dos nombres de canal al azar y te explica como suscribirte desde la app. Los titulos pasan por ntfy.sh, un servicio publico gratuito."
  [tailscale]="Entras a tus servicios desde afuera de casa sin abrir puertos. Tambien te da SSH de emergencia si Docker se rompe."
  [seguridad]="Cierra todo salvo lo necesario y banea intentos de fuerza bruta."
)

declare -A SERVICIOS=(
  [core]="caddy homepage"
  [monitoring]="grafana prometheus node-exporter pihole-exporter"
  [news]="freshrss wallabag news-filter news-filter-ui"
  [finance]="itau-email-tracker finance-tracker-ui"
  [fitbit]="fitbit-exporter fitbit-exporter-ui"
  [media]="jellyfin qbittorrent prowlarr radarr sonarr bazarr seerr"
  [home]="homeassistant"
  [ofelia]="ofelia"
)

declare -A NATIVO=( [sistema]=1 [pihole]=1 [tailscale]=1 [seguridad]=1 [avisos]=1 )

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
  [seerr]="Pedir peliculas y series desde el celular"
  [bazarr]="Descarga subtitulos"
  [homeassistant]="Domotica: automatiza luces, sensores y enchufes"
  [ofelia]="Programador de tareas"
)

# Servicios que no sirven de nada sin otro. Formato: servicio|de que depende|por que
DEPENDENCIAS=(
  "news-filter|freshrss wallabag|lee de FreshRSS y guarda en Wallabag"
  "news-filter-ui|news-filter|es el panel del filtro"
  "radarr|prowlarr qbittorrent|Prowlarr le da los indexers y qBittorrent descarga"
  "sonarr|prowlarr qbittorrent|Prowlarr le da los indexers y qBittorrent descarga"
  "bazarr|radarr sonarr|toma de Radarr y Sonarr que subtitular"
  "seerr|jellyfin radarr sonarr|pide a Radarr y Sonarr, y mira en Jellyfin lo que ya tenes"
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
#  DATOS QUE ESCRIBE EL INSTALADOR POR SU CUENTA
#
#  Estos no se preguntan nunca. Cada uno vive en el panel de un servicio que
#  todavia no esta levantado cuando corre el asistente, asi que en una maquina
#  limpia la unica respuesta posible era Enter, con su aviso amarillo de
#  "salteado". Y encima el instalador los genera solo mas tarde, en
#  configurar_servicios, cuando el servicio ya existe: se pedia un dato
#  imposible para despues pisarlo.
#
#  Esto NO es lo mismo que TOKENS_DE_CUENTA. Aquellos salen de una cuenta que
#  crea el usuario en el navegador, y se piden al final, en la guia de cuentas.
#  Estos no se piden en ningun momento.
#
#  Si la generacion automatica falla, cada cfg_* deja su propio pendiente con el
#  paso manual, asi que ninguno queda en silencio.
#
#  archivo|VARIABLE
GENERA_EL_INSTALADOR=(
"monitoring/.env|PIHOLE_API_KEY"
"news/news-filter/.env|FRESHRSS_API_PASSWORD"
"news/news-filter/.env|WALLABAG_CLIENT_ID"
"news/news-filter/.env|WALLABAG_CLIENT_SECRET"
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

# ── Quien crea las cuentas ────────────────────────────────────────────────────
#
#  Cinco servicios traen asistente de bienvenida propio, y el instalador los
#  puede saltear creando la cuenta por su API. Es mas rapido y te ahorra abrir
#  cinco paneles, pero no siempre es lo que uno quiere: capaz preferis elegir
#  tu propio usuario, o mirar cada pantalla para entender que estas instalando.
#
#  Asi que se pregunta, en vez de decidirlo por vos. Se pregunta una sola vez y
#  se puede afinar servicio por servicio.
#
#  CUENTAS_AUTO:  si = las crea el instalador · no = las creas vos
#                 (vacio = todavia no se pregunto)
CUENTAS_AUTO=""
declare -A CUENTAS_AUTO_POR_SERVICIO=()

SERVICIOS_CON_CUENTA=(
"jellyfin|Jellyfin|el asistente de 5 pantallas, tu usuario y las bibliotecas"
"seerr|Seerr|el usuario, enlazado al de Jellyfin"
"freshrss|FreshRSS|el asistente de 4 pantallas y la clave de API"
"wallabag|Wallabag|la contrasena y el cliente de API"
"homeassistant|Home Assistant|el usuario administrador"
)

# Devuelve 0 si el instalador tiene que crear la cuenta de ese servicio.
cuenta_automatica() {
    local svc="$1"
    if [ -n "${CUENTAS_AUTO_POR_SERVICIO[$svc]:-}" ]; then
        [ "${CUENTAS_AUTO_POR_SERVICIO[$svc]}" = "si" ]
        return
    fi
    [ "$CUENTAS_AUTO" != "no" ]
}

preguntar_quien_configura() {
    [ -n "$CUENTAS_AUTO" ] && return 0

    # Solo tiene sentido preguntar por los que efectivamente vas a levantar.
    local linea svc nombre que hay=()
    for linea in "${SERVICIOS_CON_CUENTA[@]}"; do
        IFS='|' read -r svc nombre que <<< "$linea"
        esta_arriba "$svc" && hay+=("$linea")
    done
    [ ${#hay[@]} -eq 0 ] && { CUENTAS_AUTO=si; return 0; }

    echo ""
    echo "  ${B}${C}Las cuentas de los servicios${N}"
    info "Estos traen su propio asistente de bienvenida, y los puedo saltear"
    info "creando la cuenta por su API:"
    echo ""
    for linea in "${hay[@]}"; do
        IFS='|' read -r svc nombre que <<< "$linea"
        printf "    ${B}·${N} %-16s %s\n" "$nombre" "$que"
    done
    echo ""
    info "Todas quedan con usuario ${B}admin${N} y la contrasena que elegiste."
    gris "     Si preferis crearlas vos, las salteo y te las dejo anotadas al final."
    echo ""
    echo "    ${B}1${N}) Las crea el instalador"
    echo "    ${B}2${N}) Las creo yo, desde el navegador"
    echo "    ${B}3${N}) Elegir servicio por servicio"
    echo ""

    local r
    read -r -p "  ${B}¿Cual?${N} [1] " r </dev/tty
    case "${r:-1}" in
        2) CUENTAS_AUTO=no
           info "Listo, no toco ninguna. Al final te digo cuales quedaron pendientes." ;;
        3) CUENTAS_AUTO=si
           echo ""
           for linea in "${hay[@]}"; do
               IFS='|' read -r svc nombre que <<< "$linea"
               if preguntar "  ¿$nombre lo configuro yo?" "s"; then
                   CUENTAS_AUTO_POR_SERVICIO[$svc]=si
               else
                   CUENTAS_AUTO_POR_SERVICIO[$svc]=no
               fi
           done ;;
        *) CUENTAS_AUTO=si ;;
    esac
    echo ""
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

    # Los avisos tienen tres estados y no dos, porque "apagados" puede ser una
    # decision tuya y no algo que falta. Un modulo que aparece incompleto para
    # siempre porque dijiste que no lo queres es un reproche, no un estado.
    local ntfy_topic ntfy_flag
    ntfy_topic=$(leer_var "$REPO/.env" NTFY_ALERTAS 2>/dev/null)
    ntfy_flag=$(leer_var "$REPO/.env" AVISOS 2>/dev/null)
    if [ "$ntfy_flag" = "no" ]; then
        ESTADO[avisos]=activo; DETALLE[avisos]="apagados a proposito"
    elif [ -n "$ntfy_topic" ] && systemctl is-enabled pi-estado.timer >/dev/null 2>&1; then
        ESTADO[avisos]=activo; DETALLE[avisos]="2 canales · mira los nombres con ./avisos.sh --canales"
    elif [ -n "$ntfy_topic" ]; then
        ESTADO[avisos]=parcial; DETALLE[avisos]="canales creados, falta programar el diagnostico"
    else
        ESTADO[avisos]=inactivo; DETALLE[avisos]="sin configurar"
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

# ── El perfil de calidad ──────────────────────────────────────────────────────
#
#  Un perfil que acepta TODAS las calidades y sigue mejorando: si baja una
#  pelicula en 1080p y manana el indexer encuentra el remux en 2160p, la
#  reemplaza sola. Eso son dos cosas juntas: todas las calidades habilitadas, y
#  el corte puesto en la mas alta para que nunca se de por satisfecho.
#
#  La lista de calidades NO se escribe a mano. Se pide el schema, que ya viene
#  con todas y en el orden correcto de peor a mejor, y se le da vuelta el
#  "allowed". Asi el dia que Radarr agregue una calidad nueva, entra sola.
PERFIL_CALIDAD="Perfeccionista"

# Las dos ultimas de Radarr no son mejor calidad: son la imagen cruda del disco.
# Pesan 50 GB o mas, no son un archivo de video sino un disco entero, y Jellyfin
# las reproduce mal o directamente no puede. Quedan fuera aunque el perfil se
# llame "todas las calidades", porque incluirlas empeora el resultado.
CALIDADES_FUERA="BR-DISK|Raw-HD"

cfg_perfil_calidad() {
    local svc="$1" puerto="$2" nombre="$3" schema cuerpo resp

    esta_arriba "$svc" || return 0

    # Idempotente: si ya existe uno con ese nombre, no se toca
    if arr_api "$svc" "$puerto" v3 GET /qualityprofile 2>/dev/null \
        | grep -q "\"name\":\"$PERFIL_CALIDAD\""; then
        gris "     $nombre ya tenia el perfil $PERFIL_CALIDAD"
        return 0
    fi

    schema=$(arr_api "$svc" "$puerto" v3 GET /qualityprofile/schema 2>/dev/null)
    if [ -z "$schema" ]; then
        aviso "$nombre: no pude leer el schema de calidades"
        pendiente "Crear el perfil $PERFIL_CALIDAD en http://$svc.pi, Settings, Profiles"
        return 1
    fi

    cuerpo=$(echo "$schema" | NOMBRE="$PERFIL_CALIDAD" FUERA="$CALIDADES_FUERA" python3 -c '
import sys, json, os, re

d = json.load(sys.stdin)
fuera = re.compile("^(" + os.environ["FUERA"] + ")$", re.I)
d["name"] = os.environ["NOMBRE"]
d["upgradeAllowed"] = True

def etiqueta(it):
    q = it.get("quality") or {}
    return q.get("name") or it.get("name") or ""

def identificador(it):
    # Una calidad suelta se identifica por quality.id; un grupo, por su id
    q = it.get("quality") or {}
    return q.get("id") if q else it.get("id")

corte = None
for it in d.get("items", []):
    nom = etiqueta(it)
    permitida = not fuera.match(nom)
    it["allowed"] = permitida
    # Los grupos traen calidades adentro: se habilitan igual que el grupo
    for sub in it.get("items", []) or []:
        sub["allowed"] = permitida
    if permitida:
        corte = identificador(it)   # queda el ultimo permitido, o sea el mejor

if corte is not None:
    d["cutoff"] = corte

print(json.dumps(d))' 2>/dev/null)

    if [ -z "$cuerpo" ]; then
        aviso "$nombre: no pude armar el perfil"
        return 1
    fi

    resp=$(arr_api "$svc" "$puerto" v3 POST /qualityprofile "$cuerpo" 2>/dev/null)
    if echo "$resp" | grep -q '"errorMessage"'; then
        aviso "$nombre: no se pudo crear el perfil"
        gris "     $(echo "$resp" | python3 -c \
            'import sys,json;print(json.load(sys.stdin)[0].get("errorMessage",""))' 2>/dev/null)"
        pendiente "Crear el perfil $PERFIL_CALIDAD en http://$svc.pi, Settings, Profiles"
        return 1
    fi

    local tope
    tope=$(echo "$resp" | python3 -c '
import sys, json
d = json.load(sys.stdin)
mejor = [i for i in d.get("items", []) if i.get("allowed")]
q = (mejor[-1].get("quality") or {}) if mejor else {}
print(len(mejor), q.get("name") or mejor[-1].get("name", "?") if mejor else "?")' 2>/dev/null)
    ok "$nombre: perfil ${B}$PERFIL_CALIDAD${N} creado ($tope como techo)"
    gris "     mejora sola cuando aparece una version mejor"
}

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

# La contrasena con la que quedo qBittorrent, para que el recuadro de la
# homepage pueda entrar. No se vuelve a preguntar en ningun lado: se recuerda
# la que se acaba de poner, que es el mismo criterio de "la clave ya existe en
# un lugar, asi que ese lugar es la fuente".
QBIT_CLAVE=""

cfg_qbittorrent() {
    local clave="$1" ck=/tmp/instalador.cookie tmp entro=0 prefs resp
    QBIT_CLAVE="$clave"
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

# Una clave de API propia de Jellyfin, para el recuadro de la homepage y para
# que Radarr le pida reescanear al importar.
#
# Se reusa la que ya creamos si existe, en vez de crear una nueva en cada
# corrida: si no, en un ano Jellyfin tendria doce claves nuestras dando vueltas
# y ninguna forma de saber cual esta en uso.
_jf_clave_guardada() {
    jf_api GET "/Auth/Keys" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = d.get("Items") if isinstance(d, dict) else d
for i in items or []:
    if i.get("AppName") == "pi-services":
        print(i.get("AccessToken", ""))
        break
' 2>/dev/null
}

api_key_jellyfin() {
    esta_arriba jellyfin || return 1
    [ -n "$JF_TOKEN" ] || return 1
    local k
    k=$(_jf_clave_guardada)
    if [ -z "$k" ]; then
        jf_api POST "/Auth/Keys?App=pi-services" >/dev/null 2>&1
        k=$(_jf_clave_guardada)
    fi
    [ -n "$k" ] || return 1
    echo "$k"
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

# Cuantas cuentas tiene Jellyfin, contadas en su base.
#
# No sirve preguntarle a /Users/Public: esa lista esconde a los usuarios
# marcados como ocultos en la pantalla de login, asi que un servidor con
# cuentas puede contestar vacio y nos haria pisar una instalacion sana.
jf_usuarios() {
    local cfg; cfg=$(ruta_config jellyfin)
    if [ -z "$cfg" ] || ! sudo test -f "$cfg/data/jellyfin.db"; then
        echo "-1"; return 1
    fi
    sudo python3 - "$cfg/data/jellyfin.db" <<'PY' 2>/dev/null || echo "-1"
import sqlite3, sys
c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
print(list(c.execute("SELECT count(*) FROM Users"))[0][0])
PY
}

# Vuelve a abrir el asistente de arranque.
#
# Hace falta para salir de un estado del que Jellyfin no sale solo: el asistente
# marcado como completo pero sin ninguna cuenta. Con el asistente cerrado,
# /Startup/User contesta 401 y no queda ningun usuario con quien autenticar, asi
# que no se entra ni reseteando la contrasena, porque no hay a quien resetearsela.
#
# Se para el contenedor antes de tocar el XML: Jellyfin lee la marca al arrancar
# y reescribe el archivo entero al apagarse, o sea que editarlo en caliente se
# pierde en el proximo stop.
jf_reabrir_asistente() {
    local cfg; cfg=$(ruta_config jellyfin)
    if [ -z "$cfg" ] || ! sudo test -f "$cfg/config/system.xml"; then
        return 1
    fi
    $DOCKER stop jellyfin >/dev/null 2>&1
    sudo sed -i 's|<IsStartupWizardCompleted>true</IsStartupWizardCompleted>|<IsStartupWizardCompleted>false</IsStartupWizardCompleted>|' \
        "$cfg/config/system.xml" 2>/dev/null
    $DOCKER start jellyfin >/dev/null 2>&1
    esperar_http jellyfin 8096 /System/Info/Public || return 1
    [ "$(jf_api GET /System/Info/Public 2>/dev/null | python3 -c \
        'import sys,json;print(json.load(sys.stdin).get("StartupWizardCompleted"))' 2>/dev/null)" != "True" ]
}

cfg_jellyfin() {
    local clave="$1" listo resp
    esperar_http jellyfin 8096 /System/Info/Public || { aviso "Jellyfin no contesta"; pendiente "Configurar Jellyfin: no contestaba al instalar. Volve a correr el instalador"; return 1; }

    listo=$(jf_api GET /System/Info/Public 2>/dev/null | python3 -c \
        'import sys,json;print(json.load(sys.stdin).get("StartupWizardCompleted"))' 2>/dev/null)

    # Asistente cerrado y cero cuentas: el servidor quedo sin forma de entrar.
    # Reabrirlo es la unica salida, y es seguro justamente porque no hay ninguna
    # cuenta que perder.
    if [ "$listo" = "True" ] && [ "$(jf_usuarios)" = "0" ]; then
        aviso "Jellyfin: el asistente figura completo pero no hay ninguna cuenta"
        info "Reabro el asistente para crear el usuario admin."
        if jf_reabrir_asistente; then
            listo="False"
        else
            aviso "Jellyfin: no pude reabrir el asistente"
            pendiente "Crear el usuario admin de Jellyfin en http://jellyfin.pi"
            return 1
        fi
    fi

    if [ "$listo" != "True" ]; then
        jf_api POST /Startup/Configuration \
            '{"UICulture":"es","MetadataCountryCode":"UY","PreferredMetadataLanguage":"es"}' >/dev/null 2>&1
        resp=$(jf_api POST /Startup/User "$(CLAVE="$clave" python3 -c \
            'import json,os;print(json.dumps({"Name":"admin","Password":os.environ["CLAVE"]}))')" 2>&1)

        # Comprobar la cuenta ANTES de cerrar el asistente, no despues.
        #
        # Cerrarlo sin cuenta deja el servidor inaccesible y sin vuelta atras por
        # la via normal, que es exactamente lo que pasaba cuando este POST fallaba
        # en silencio. Si fallo, el asistente queda ABIERTO a proposito: es feo
        # pero se arregla desde el navegador en un minuto.
        if [ "$(jf_usuarios)" = "0" ]; then
            aviso "Jellyfin: no pude crear el usuario admin"
            [ -n "$resp" ] && gris "     respondio: $(echo "$resp" | tr -d '\n' | cut -c1-200)"
            gris "     dejo el asistente abierto: entra a http://jellyfin.pi y crealo vos"
            pendiente "Crear el usuario admin de Jellyfin en http://jellyfin.pi"
            return 1
        fi

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

    # Dos bibliotecas, y las dos importan.
    #
    # La de series no es un extra: Seerr mira JELLYFIN para saber que ya tenes.
    # Sin ella, pedis una serie, Sonarr la baja, y Seerr nunca la marca como
    # disponible porque no la ve en ningun lado. El sintoma es que todo parece
    # andar salvo que la lista de pedidos no se vacia nunca.
    #
    # Y el tipo de coleccion tiene que ser el correcto: Jellyfin busca los
    # metadatos de forma distinta para peliculas y para series.
    local bibliotecas; bibliotecas=$(jf_api GET /Library/VirtualFolders 2>/dev/null)
    local par nombre ruta tipo
    for par in "Peliculas|/media/movies|movies" "Series|/media/tv|tvshows"; do
        IFS='|' read -r nombre ruta tipo <<< "$par"
        if echo "$bibliotecas" | grep -q "\"$ruta\""; then
            gris "     la biblioteca de $nombre ya existia"
            continue
        fi
        # Tiene que existir del lado del disco o Jellyfin la crea vacia y muda
        mkdir -p "$(das_ruta)/media/$(basename "$ruta")" 2>/dev/null
        jf_api POST "/Library/VirtualFolders?name=$nombre&collectionType=$tipo&refreshLibrary=true" \
            "{\"LibraryOptions\":{\"PathInfos\":[{\"Path\":\"$ruta\"}],\"EnableRealtimeMonitor\":true}}" >/dev/null 2>&1
        ok "Jellyfin: biblioteca ${B}$nombre${N} en $ruta"
    done

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

# ── Seerr ─────────────────────────────────────────────────────────────────────
#
#  Seerr es la puerta de entrada del stack: pedis una pelicula o una serie desde
#  el celular y el se la pasa a Radarr o a Sonarr, y mira en Jellyfin lo que ya
#  tenes para no ofrecerte lo que ya esta.
#
#  Dos cosas lo hacen distinto de los demas:
#
#  Su imagen NO trae curl, asi que las llamadas salen desde el HOST contra la IP
#  del contenedor. Usar esperar_http, que hace docker exec curl, lo daria por
#  caido estando perfecto.
#
#  Y su arranque inicial NO es repetible: si Jellyfin ya esta configurado, el
#  POST de bootstrap devuelve error. Como todo este repo se apoya en que volver
#  a correr el instalador es seguro, hay que preguntar antes.

# Donde preguntarle a un contenedor si responde.
#
# Ojo con el caso de la red del host: ahi .IPAddress no viene vacio, viene con
# el texto "invalid IP", que es lo que imprime el template de Go cuando el
# campo no aplica. Sin filtrarlo se arma una URL http://invalid:8123 y el
# resultado es que un servicio perfectamente sano figura como caido. Le paso
# al diagnostico con Home Assistant.
ip_de() {
    local modo; modo=$($DOCKER inspect -f '{{.HostConfig.NetworkMode}}' "$1" 2>/dev/null)
    [ "$modo" = "host" ] && { echo 127.0.0.1; return; }
    local ip
    ip=$($DOCKER inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null | awk '{print $1}')
    case "$ip" in invalid|"") return 1 ;; esac
    echo "$ip"
}

seerr_api() {
    local metodo="$1" ruta="$2" cuerpo="${3:-}" key="${4:-}" ip
    ip=$(ip_de seerr)
    [ -n "$ip" ] || return 1
    if [ -n "$cuerpo" ]; then
        curl -s -X "$metodo" --max-time 40 -H "Content-Type: application/json" \
            ${key:+-H "X-Api-Key: $key"} -d "$cuerpo" "http://$ip:5055/api/v1$ruta"
    else
        curl -s -X "$metodo" --max-time 40 ${key:+-H "X-Api-Key: $key"} \
            "http://$ip:5055/api/v1$ruta"
    fi
}

# Su configuracion vive en un JSON adentro del contenedor. De ahi sale la API
# key, y tambien si el bootstrap ya se hizo.
seerr_config() {
    $DOCKER exec seerr cat /app/config/settings.json 2>/dev/null
}

seerr_ya_arrancado() {
    seerr_config | python3 -c '
import sys, json
try:
    print("si" if (json.load(sys.stdin).get("jellyfin", {}).get("ip") or "") else "no")
except Exception:
    print("no")' 2>/dev/null | grep -q si
}

api_key_seerr() {
    seerr_config | python3 -c \
        'import sys,json;print(json.load(sys.stdin).get("main",{}).get("apiKey",""))' 2>/dev/null
}

# El id del perfil de calidad por su nombre, para decirle a Seerr con cual pedir
id_perfil() {
    arr_api "$1" "$2" v3 GET /qualityprofile 2>/dev/null | NOMBRE="$3" python3 -c '
import sys, json, os
n = os.environ["NOMBRE"]
for p in json.load(sys.stdin):
    if p.get("name") == n:
        print(p["id"]); break' 2>/dev/null
}

esperar_seerr() {
    local i ip code
    for i in $(seq 1 45); do
        esta_arriba seerr || return 1
        ip=$(ip_de seerr)
        if [ -n "$ip" ]; then
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$ip:5055/api/v1/status" 2>/dev/null)
            case "$code" in ""|000|5*) ;; *) return 0 ;; esac
        fi
        sleep 3
    done
    return 1
}

# Conecta Radarr o Sonarr a Seerr, con el perfil de calidad ya elegido
seerr_conectar_arr() {
    local tipo="$1" svc="$2" puerto="$3" carpeta="$4" key="$5" kapi perfil resp

    esta_arriba "$svc" || return 0
    kapi=$(api_key_arr "$svc")
    [ -n "$kapi" ] || return 0

    if seerr_api GET "/settings/$tipo" "" "$key" 2>/dev/null | grep -q '"hostname"'; then
        gris "     $svc ya estaba conectado a Seerr"
        return 0
    fi

    perfil=$(id_perfil "$svc" "$puerto" "$PERFIL_CALIDAD")
    [ -n "$perfil" ] || perfil=1

    local cuerpo
    cuerpo=$(SVC="$svc" PUERTO="$puerto" KAPI="$kapi" PERFIL="$perfil" \
             NOMBRE_PERFIL="$PERFIL_CALIDAD" CARPETA="$carpeta" TIPO="$tipo" python3 -c '
import json, os
t = os.environ["TIPO"]
d = {
  "name": os.environ["SVC"].capitalize(),
  "hostname": os.environ["SVC"],
  "port": int(os.environ["PUERTO"]),
  "apiKey": os.environ["KAPI"],
  "useSsl": False,
  "baseUrl": "",
  "activeProfileId": int(os.environ["PERFIL"]),
  "activeProfileName": os.environ["NOMBRE_PERFIL"],
  "activeDirectory": os.environ["CARPETA"],
  "is4k": False,
  "isDefault": True,
  "externalUrl": "http://" + os.environ["SVC"] + ".pi",
  "syncEnabled": True,
  "preventSearch": False,
  "tagRequests": False,
}
if t == "radarr":
    d["minimumAvailability"] = "released"
else:
    d["enableSeasonFolders"] = True
print(json.dumps(d))' 2>/dev/null)

    resp=$(seerr_api POST "/settings/$tipo" "$cuerpo" "$key" 2>/dev/null)
    if echo "$resp" | grep -qiE '"message"|error'; then
        aviso "Seerr: no pude conectar $svc"
        gris "     $(echo "$resp" | head -c 120)"
        pendiente "Conectar $svc en http://seerr.pi, Settings, Services"
    else
        ok "Seerr: ${B}$svc${N} conectado, pidiendo con el perfil $PERFIL_CALIDAD"
    fi
}

cfg_seerr() {
    local clave="$1" key resp

    esperar_seerr || {
        aviso "Seerr no contesta"
        pendiente "Configurar Seerr: no contestaba al instalar. Volve a correr el instalador"
        return 1
    }

    # ── El arranque: crea el usuario admin Y conecta Jellyfin de una vez ──
    #
    # Un solo POST hace todo: valida contra Jellyfin, exige que el usuario sea
    # administrador, crea el admin de Seerr y se genera solo una API key en
    # Jellyfin. No hay que darle ninguna clave de Jellyfin aparte.
    if seerr_ya_arrancado; then
        gris "     Seerr ya estaba enlazado con Jellyfin"
    else
        # urlBase y port van SIEMPRE, aunque urlBase quede vacio: Seerr arma la
        # URL con un template y sin ellos queda "http://jellyfin:8096undefined",
        # que falla con un error de conexion que no dice nada de esto.
        local arranque
        arranque=$(CLAVE="$clave" python3 -c '
import json, os
print(json.dumps({
  "username": "admin",
  "password": os.environ["CLAVE"],
  "hostname": "jellyfin",
  "port": 8096,
  "urlBase": "",
  "useSsl": False,
  "serverType": 2}))' 2>/dev/null)

        resp=$(seerr_api POST /auth/jellyfin "$arranque" 2>/dev/null)
        if ! seerr_ya_arrancado; then
            aviso "Seerr: no pude enlazarlo con Jellyfin"
            gris "     $(echo "$resp" | head -c 140)"
            pendiente "Terminar el arranque de Seerr en http://seerr.pi"
            return 1
        fi
        ok "Seerr: usuario ${B}admin${N} creado y Jellyfin enlazado"
    fi

    key=$(api_key_seerr)
    if [ -z "$key" ]; then
        aviso "Seerr: no encontre su clave de API"
        return 1
    fi

    # ── Las bibliotecas de Jellyfin ──
    #
    # Van DOS llamadas y en este orden. La primera con sync=true descubre las
    # bibliotecas; la segunda las habilita. Llamar solo con sync=true las
    # DESHABILITA todas, porque el codigo mapea "enabled" contra la lista que le
    # pasaste, y si no pasaste ninguna, ninguna queda habilitada.
    local libs
    libs=$(seerr_api GET "/settings/jellyfin/library?sync=true" "" "$key" 2>/dev/null)
    local ids
    ids=$(echo "$libs" | python3 -c '
import sys, json
try:
    print(",".join(x["id"] for x in json.load(sys.stdin)))
except Exception:
    print("")' 2>/dev/null)
    if [ -n "$ids" ]; then
        seerr_api GET "/settings/jellyfin/library?enable=$ids" "" "$key" >/dev/null 2>&1
        ok "Seerr: $(echo "$ids" | tr ',' '\n' | wc -l) bibliotecas de Jellyfin habilitadas"
    fi

    # ── Radarr y Sonarr, con el perfil de calidad ya elegido ──
    seerr_conectar_arr radarr radarr 7878 /data/media/movies "$key"
    seerr_conectar_arr sonarr sonarr 8989 /data/media/tv     "$key"

    # ── Cerrar el asistente ──
    seerr_api POST /settings/initialize "" "$key" >/dev/null 2>&1
    ok "Seerr listo en ${B}http://seerr.pi${N}"
}

# ── Bazarr ────────────────────────────────────────────────────────────────────

api_key_bazarr() {
    # ruta_config devuelve la raiz del volumen; el YAML cuelga de config/.
    local raiz; raiz=$(ruta_config bazarr)
    [ -n "$raiz" ] || return 1
    sudo grep -A20 '^auth:' "$raiz/config/config.yaml" 2>/dev/null \
        | grep apikey | head -1 | awk '{print $2}'
}

# El perfil de idiomas es el paso que mas se olvida de todo el stack: sin uno,
# Bazarr corre, se ve sano, se conecta a Radarr y a Sonarr, y no baja un solo
# subtitulo nunca. Nada avisa.
#
# Que idiomas queres es una eleccion tuya, asi que el instalador no adivina:
# deja Espanol e Ingles, que es lo que sirve aca, y te dice donde cambiarlo.
BAZARR_IDIOMAS="es en"
BAZARR_PERFIL="Espanol e Ingles"

cfg_bazarr_idiomas() {
    esta_arriba bazarr || return 0
    local ip key; ip=$(ip_de bazarr); key=$(api_key_bazarr)
    [ -n "$ip" ] && [ -n "$key" ] || return 0

    local previos
    previos=$(curl -s --max-time 25 -H "X-API-KEY: $key" \
        "http://$ip:6767/api/system/languages/profiles" 2>/dev/null)
    if [ -n "$previos" ] && [ "$previos" != "[]" ]; then
        gris "     Bazarr ya tenia un perfil de idiomas"
        return 0
    fi

    local cuerpo idioma args=()
    cuerpo=$(IDIOMAS="$BAZARR_IDIOMAS" NOMBRE="$BAZARR_PERFIL" python3 -c '
import os, json
items = [{"id": i, "language": c, "audio_exclude": "False",
          "hi": "False", "forced": "False"}
         for i, c in enumerate(os.environ["IDIOMAS"].split())]
print(json.dumps([{"profileId": 1, "name": os.environ["NOMBRE"], "items": items,
                   "cutoff": None, "mustContain": [], "mustNotContain": [],
                   "originalFormat": False, "tag": None}]))' 2>/dev/null)
    [ -n "$cuerpo" ] || return 1

    for idioma in $BAZARR_IDIOMAS; do
        args+=(--data-urlencode "settings-general-enabled_languages=$idioma")
    done

    # Los perfiles no se guardan por su propio endpoint: ese contesta 405. Van
    # por el de configuracion general, con el perfil serializado adentro.
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
        -H "X-API-KEY: $key" --data-urlencode "languages-profiles=$cuerpo" \
        "${args[@]}" "http://$ip:6767/api/system/settings" 2>/dev/null)

    case "$code" in 200|204) ;; *)
        aviso "Bazarr: no pude crear el perfil de idiomas (HTTP $code)"
        pendiente "Crear el perfil de idiomas en http://bazarr.pi, Settings, Languages"
        return 1 ;;
    esac

    sleep 8
    previos=$(curl -s --max-time 25 -H "X-API-KEY: $key" \
        "http://$ip:6767/api/system/languages/profiles" 2>/dev/null)
    if [ -z "$previos" ] || [ "$previos" = "[]" ]; then
        aviso "Bazarr: dijo que guardo el perfil pero despues no estaba"
        pendiente "Crear el perfil de idiomas en http://bazarr.pi, Settings, Languages"
        return 1
    fi

    ok "Bazarr: perfil de idiomas ${B}$BAZARR_PERFIL${N} creado"
    gris "     sin perfil no baja ningun subtitulo; cambialo en Settings, Languages"
}

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

# ── Los widgets de la homepage ────────────────────────────────────────────────
#
#  La homepage puede mostrar datos en vivo de cada servicio: cuantas peliculas
#  hay, cuantas se estan bajando, cuantos pedidos quedan pendientes. Para eso
#  necesita la clave de API de cada uno.
#
#  Esas claves YA EXISTEN: Radarr y Sonarr las tienen en su config.xml, Seerr en
#  su settings.json. Pedirtelas seria hacerte copiar y pegar algo que la Pi ya
#  sabe. Se leen y se escriben en homepage/.env, que no va a git, y en
#  services.yaml quedan como {{HOMEPAGE_VAR_*}}, que si va.
#
#  Asi el archivo versionado nunca tiene un secreto adentro, y vos no tocas nada.
cfg_homepage_widgets() {
    esta_arriba homepage || return 0

    local escritas=0 k

    k=$(api_key_arr radarr)
    [ -n "$k" ] && { escribir_var homepage/.env HOMEPAGE_VAR_RADARR_KEY "$k"; escritas=$((escritas+1)); }

    k=$(api_key_arr sonarr)
    [ -n "$k" ] && { escribir_var homepage/.env HOMEPAGE_VAR_SONARR_KEY "$k"; escritas=$((escritas+1)); }

    k=$(api_key_arr prowlarr)
    [ -n "$k" ] && { escribir_var homepage/.env HOMEPAGE_VAR_PROWLARR_KEY "$k"; escritas=$((escritas+1)); }

    if esta_arriba seerr; then
        k=$(api_key_seerr)
        [ -n "$k" ] && { escribir_var homepage/.env HOMEPAGE_VAR_SEERR_KEY "$k"; escritas=$((escritas+1)); }
    fi

    # Jellyfin y qBittorrent tienen recuadro nativo en la homepage y estaban
    # apagados: solo mostraban un puntito de "esta vivo". Con esto pasan a
    # mostrar quien esta reproduciendo y que se esta bajando, que es lo que
    # tenia el boceto original de la pantalla de media.
    if esta_arriba jellyfin; then
        k=$(api_key_jellyfin) || k=""
        if [ -n "$k" ]; then
            escribir_var homepage/.env HOMEPAGE_VAR_JELLYFIN_KEY "$k"; escritas=$((escritas+1))
        else
            pendiente "El recuadro de Jellyfin en la homepage necesita que el instalador configure Jellyfin"
        fi
    fi

    # Aca no hay clave de API que leer: qBittorrent se entra con usuario y
    # contrasena, asi que se usa la que le acabamos de poner.
    if esta_arriba qbittorrent && [ -n "$QBIT_CLAVE" ]; then
        escribir_var homepage/.env HOMEPAGE_VAR_QBIT_USER admin
        escribir_var homepage/.env HOMEPAGE_VAR_QBIT_PASS "$QBIT_CLAVE"
        escritas=$((escritas+1))
    fi

    [ "$escritas" -eq 0 ] && return 0

    # El contenedor tiene las variables cargadas en memoria: hay que recrearlo
    $DOCKER compose up -d --force-recreate homepage >/dev/null 2>&1
    olvidar_estado
    sleep 5

    # Escribirlas no alcanza, y esto costo caro: el compose de la homepage no
    # tenia env_file, asi que las claves quedaban en el .env sin entrar nunca al
    # contenedor. Los recuadros mandaban la clave vacia, cada servicio contestaba
    # 401 o 403, y la homepage decia "API Error" sin decir por que. Se comprueba
    # adentro, que es el unico lugar donde la respuesta es la verdadera.
    local llegaron
    # Se cuentan todas las HOMEPAGE_VAR_ y no solo las que terminan en _KEY:
    # qBittorrent no tiene clave de API, entra con usuario y contrasena.
    llegaron=$($DOCKER exec homepage sh -c 'env | grep -c "^HOMEPAGE_VAR_"' 2>/dev/null | tr -d '[:space:]')
    [ -n "$llegaron" ] || llegaron=0

    if [ "$llegaron" -lt "$escritas" ]; then
        aviso "Homepage: escribi $escritas $(plural "$escritas" "clave" "claves") pero al contenedor $(plural "$llegaron" "llego $llegaron" "llegaron $llegaron")"
        gris "     revisa que homepage/docker-compose.yml tenga env_file: - .env"
        pendiente "Los recuadros de la homepage van a decir 'API Error' hasta que las claves entren al contenedor"
        return 1
    fi

    ok "Homepage: $escritas $(plural "$escritas" "clave leida" "claves leidas") sola, sin copiar nada"
    gris "     comprobado adentro del contenedor, no solo escrito en el .env"
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
    local H="[" h n=0 faltan=0 guardados
    for h in $(hosts_del_caddyfile); do
        H="$H\"$IP_FIJA $h\","
        n=$((n+1))
    done
    [ "$n" -eq 0 ] && { aviso "No pude leer los nombres del Caddyfile"; return 1; }

    if ! sudo pihole-FTL --config dns.hosts "${H%,}]" >/dev/null 2>&1; then
        aviso "Pi-hole no acepto los registros DNS"
        pendiente "Cargar los registros .pi a mano en Pi-hole"
        return 1
    fi

    # De fabrica Pi-hole atiende solo a la red local y descarta lo que llega por
    # Tailscale, que es otra subred (100.64.0.0/10). El sintoma engana: la VPN
    # conecta, el servidor responde por IP, y sin embargo ningun nombre .pi
    # resuelve desde afuera de casa, como si el DNS no existiera.
    #
    # De paso, con ALL deja de importar dns.interface, que se queda con el nombre
    # de placa de la maquina donde se instalo la primera vez (eth0 en la Pi) y no
    # coincide con el de la maquina nueva.
    sudo pihole-FTL --config dns.listeningMode ALL >/dev/null 2>&1

    sudo systemctl restart pihole-FTL >/dev/null 2>&1
    sleep 2

    # Comprobar que quedaron guardados, no solo que el comando no dio error.
    # Un registro que no queda no se nota hasta que abris un .pi en el navegador,
    # mucho despues, y ahi no se parece en nada a un problema del instalador.
    guardados=$(sudo pihole-FTL --config dns.hosts 2>/dev/null)
    for h in $(hosts_del_caddyfile); do
        case "$guardados" in
            *" $h"*) ;;
            *) faltan=$((faltan+1)) ;;
        esac
    done
    if [ "$faltan" -gt 0 ]; then
        aviso "Pi-hole acepto los registros pero faltan $faltan de $n"
        pendiente "Revisar los registros .pi en Pi-hole"
        return 1
    fi

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

# ── Las tres cuentas que ya no tenes que crear a mano ─────────────────────────
#
#  FreshRSS, Wallabag y la clave de API de Pi-hole eran tres de los cinco datos
#  que el instalador te terminaba pidiendo, y los tres con el mismo problema:
#  solo existen DESPUES de crear una cuenta en el navegador. Eso obligaba a
#  cortar la instalacion, abrir tres paneles, y volver a pegar valores.
#
#  Los tres se pueden hacer sin navegador. Cada uno por un camino distinto:
#  FreshRSS trae comandos propios, Wallabag necesita una fila en su base, y
#  Pi-hole tiene un endpoint que genera la clave.

# FreshRSS se instala entero por linea de comandos, incluida la clave de API.
# Es lo mejor que le puede pasar a un instalador: el asistente de cuatro
# pantallas y la clave de API son el mismo comando.
freshrss_con_cuenta() {
    esta_arriba freshrss || return 1
    [ -n "$($DOCKER exec freshrss php /var/www/FreshRSS/cli/list-users.php 2>/dev/null | tr -d '[:space:]')" ]
}

cfg_freshrss() {
    local clave="$1" env_filtro="$REPO/news/news-filter/.env"
    esta_arriba freshrss || return 0

    if freshrss_con_cuenta; then
        gris "     FreshRSS ya tenia su cuenta, no la toco"
        # La clave de API no se puede releer ni cambiar para un usuario que ya
        # existe: FreshRSS la guarda hasheada y actualize-user solo toma --user.
        # Asi que si falta, sigue siendo tuya.
        completa "$env_filtro" FRESHRSS_API_PASSWORD || \
            pendiente "Poner la clave de API de FreshRSS en news/news-filter/.env (Perfil, API)"
        return 0
    fi

    if ! $DOCKER exec freshrss php /var/www/FreshRSS/cli/do-install.php \
            --default-user admin --auth-type form --language es \
            --db-type sqlite --api-enabled >/dev/null 2>&1; then
        aviso "FreshRSS: no pude completar la instalacion"
        pendiente "Entrar a http://freshrss.pi y hacer el asistente a mano"
        return 1
    fi

    if ! $DOCKER exec freshrss php /var/www/FreshRSS/cli/create-user.php \
            --user admin --password "$clave" --api-password "$clave" \
            --language es >/dev/null 2>&1; then
        aviso "FreshRSS: quedo instalado pero no pude crear el usuario"
        pendiente "Entrar a http://freshrss.pi y crear el usuario admin"
        return 1
    fi

    escribir_var "$env_filtro" FRESHRSS_API_PASSWORD "$clave"
    ok "FreshRSS: cuenta ${B}admin${N} creada y API habilitada"
    gris "     la clave de API quedo escrita sola, no hace falta que la copies"
}

# Wallabag no tiene comando para crear un cliente de API: es la unica pieza que
# su consola no cubre. La fila se escribe a mano en su base y despues se
# COMPRUEBA pidiendo un token de verdad. Si el token no sale, se borra la fila
# y queda el paso manual, en vez de dejar credenciales que no sirven.
cfg_wallabag() {
    local clave="$1" env_filtro="$REPO/news/news-filter/.env"
    esta_arriba wallabag || return 0

    # La contrasena si tiene comando propio, y es idempotente.
    if $DOCKER exec wallabag /var/www/wallabag/bin/console --env=prod \
            fos:user:change-password wallabag "$clave" >/dev/null 2>&1; then
        escribir_var "$env_filtro" WALLABAG_PASSWORD "$clave"
    else
        aviso "Wallabag: no pude cambiarle la contrasena"
        pendiente "Entrar a http://wallabag.pi con wallabag/wallabag y cambiarla"
        return 1
    fi

    if completa "$env_filtro" WALLABAG_CLIENT_ID && \
       completa "$env_filtro" WALLABAG_CLIENT_SECRET; then
        ok "Wallabag: contrasena puesta, el cliente de API ya existia"
        return 0
    fi

    local vol; vol=$($DOCKER volume inspect pi-services_wallabag-data -f '{{.Mountpoint}}' 2>/dev/null)
    local base="$vol/db/wallabag.sqlite"
    if [ -z "$vol" ] || ! sudo test -f "$base"; then
        aviso "Wallabag: no encontre su base para crear el cliente de API"
        pendiente "Crear el cliente de API en http://wallabag.pi, Configuracion, Clientes API"
        return 1
    fi

    # Con el contenedor andando, escribir su SQLite desde afuera es pedir un
    # "database is locked" en el peor momento.
    $DOCKER stop wallabag >/dev/null 2>&1
    olvidar_estado

    local datos
    datos=$(sudo BASE="$base" python3 - <<'PYEOF' 2>/dev/null
import os, sqlite3, secrets
# redirect_uris y allowed_grant_types son arrays serializados de PHP: Doctrine
# los lee asi y no acepta JSON.
VACIO = "a:0:{}"
TIPOS = 'a:2:{i:0;s:8:"password";i:1;s:13:"refresh_token";}'
try:
    c = sqlite3.connect(os.environ["BASE"])
    rid, sec = secrets.token_hex(16), secrets.token_hex(32)
    cur = c.execute(
        "insert into wallabag_oauth2_clients "
        "(user_id, random_id, secret, name, redirect_uris, allowed_grant_types) "
        "values (?,?,?,?,?,?)",
        (None, rid, sec, "news-filter", VACIO, TIPOS))
    c.commit()
    # El client_id que espera la API es el id de la fila y el random_id juntos.
    print(f"{cur.lastrowid}_{rid} {sec} {cur.lastrowid}")
    c.close()
except Exception:
    pass
PYEOF
)

    $DOCKER start wallabag >/dev/null 2>&1
    olvidar_estado

    local cid csecret fila
    read -r cid csecret fila <<< "$datos"
    if [ -z "$cid" ] || [ -z "$csecret" ]; then
        aviso "Wallabag: no pude crear el cliente de API en su base"
        pendiente "Crear el cliente de API en http://wallabag.pi, Configuracion, Clientes API"
        return 1
    fi

    # La comprobacion real: pedir un token con lo que acabo de escribir.
    esperar_http wallabag 80 / >/dev/null 2>&1
    local ip token
    ip=$(ip_de wallabag)
    token=$(curl -s --max-time 25 -X POST "http://$ip:80/oauth/v2/token" \
        -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"password\",\"client_id\":\"$cid\",\"client_secret\":\"$csecret\",\"username\":\"wallabag\",\"password\":\"$clave\"}" \
        2>/dev/null | grep -o '"access_token"')

    if [ -z "$token" ]; then
        # No dejar credenciales que no sirven: se borra la fila y queda el paso
        # manual, que es peor pero es honesto.
        $DOCKER stop wallabag >/dev/null 2>&1
        sudo BASE="$base" FILA="$fila" python3 -c '
import os, sqlite3
c = sqlite3.connect(os.environ["BASE"])
c.execute("delete from wallabag_oauth2_clients where id=?", (int(os.environ["FILA"]),))
c.commit(); c.close()' >/dev/null 2>&1
        $DOCKER start wallabag >/dev/null 2>&1
        olvidar_estado
        aviso "Wallabag: el cliente que cree no daba token, lo deshice"
        pendiente "Crear el cliente de API en http://wallabag.pi, Configuracion, Clientes API"
        return 1
    fi

    escribir_var "$env_filtro" WALLABAG_CLIENT_ID "$cid"
    escribir_var "$env_filtro" WALLABAG_CLIENT_SECRET "$csecret"
    ok "Wallabag: contrasena puesta y cliente de API creado"
    gris "     comprobado pidiendo un token de verdad, no solo escrito"
}

# La clave de API de Pi-hole no es la del panel: es una "app password" aparte,
# que se genera con el panel abierto y se guarda hasheada. El endpoint que la
# genera devuelve las dos mitades, asi que se puede hacer sin navegador.
cfg_pihole_api() {
    local clave="$1" env_mon="$REPO/monitoring/.env"
    command -v pihole-FTL >/dev/null 2>&1 || return 0

    if completa "$env_mon" PIHOLE_API_KEY && \
       [ -n "$(sudo pihole-FTL --config webserver.api.app_pwhash 2>/dev/null | tr -d '"')" ]; then
        gris "     Pi-hole ya tenia su clave de API"
        return 0
    fi

    local sid
    sid=$(curl -s --max-time 20 -X POST -H "Content-Type: application/json" \
          -d "{\"password\":\"$clave\"}" http://127.0.0.1:8181/api/auth 2>/dev/null \
          | python3 -c 'import sys,json; print(json.load(sys.stdin).get("session",{}).get("sid",""))' 2>/dev/null)
    if [ -z "$sid" ]; then
        aviso "Pi-hole: no pude entrar a su API con la contrasena del panel"
        pendiente "Generar la clave de API en pihole.pi, Settings, API, y ponerla en monitoring/.env"
        return 1
    fi

    local par app_pass app_hash
    par=$(curl -s --max-time 20 -H "X-FTL-SID: $sid" http://127.0.0.1:8181/api/auth/app 2>/dev/null \
          | python3 -c '
import sys, json
d = json.load(sys.stdin); a = d.get("app", d)
print(a.get("password", ""), a.get("hash", ""))' 2>/dev/null)
    read -r app_pass app_hash <<< "$par"
    curl -s --max-time 10 -X DELETE -H "X-FTL-SID: $sid" http://127.0.0.1:8181/api/auth >/dev/null 2>&1

    if [ -z "$app_pass" ] || [ -z "$app_hash" ]; then
        aviso "Pi-hole: su API no me devolvio una clave"
        pendiente "Generar la clave de API en pihole.pi, Settings, API, y ponerla en monitoring/.env"
        return 1
    fi

    # El hash va en la configuracion; la contrasena es la clave que usa el
    # exporter. Guardar solo una de las dos deja el par roto.
    if ! sudo pihole-FTL --config webserver.api.app_pwhash "$app_hash" >/dev/null 2>&1; then
        aviso "Pi-hole: no pude guardarle el hash de la clave de API"
        return 1
    fi

    escribir_var "$env_mon" PIHOLE_API_KEY "$app_pass"
    ok "Pi-hole: clave de API generada y guardada sola"
    gris "     sin ella el tablero de Pi-hole en Grafana queda vacio para siempre"

    if esta_arriba pihole-exporter; then
        $DOCKER compose up -d --force-recreate pihole-exporter >/dev/null 2>&1
        olvidar_estado
    fi
}

# ── Home Assistant detras de Caddy ────────────────────────────────────────────
#
#  Home Assistant no confia en un proxy porque se lo pidas. Toma el bloque http:
#  de configuration.yaml, lo guarda como "pending", arranca con el, y si en
#  cinco minutos nadie lo CONFIRMA lo revierte, lo marca not_promoted y no lo
#  reintenta nunca mas. A partir de ahi casa.pi contesta 400 para siempre.
#
#  Y confirmarlo no es cualquier cosa. Leyendo su codigo (components/http/), la
#  unica via es el comando WebSocket autenticado `http/config/promote` que manda
#  el frontend. O sea: hace falta usuario, sesion, y que la pagina cargue por el
#  proxy que todavia no anda. Un circulo cerrado.
#
#  La salida es hacer lo mismo que hace ese comando, pero con HA parado y
#  escribiendo su store: promover-proxy.py. Ademas deja yaml_migration_done en
#  true, que es lo que evita que el YAML se vuelva a escenificar como pending en
#  cada arranque. Sin eso el problema vuelve al siguiente reinicio.
#
#  Dos cosas se aprendieron a los golpes y estan en ese script: la clave
#  `pending` se deja en null y no se borra, y la config que se promueve es la
#  que genero HA tal cual, no una armada a mano.
ha_por_caddy() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        -H "Host: casa.pi" "http://$IP_FIJA/" 2>/dev/null
}

HA_STORE="config/.storage/http"

ha_escucha() {
    local i c
    for i in $(seq 1 24); do
        c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8123/ 2>/dev/null)
        case "$c" in 200|302) return 0 ;; esac
        sleep 15
    done
    return 1
}

# Promueve con HA parado y lo vuelve a levantar. Devuelve 0 si quedo promovida
# o si ya lo estaba.
ha_promover() {
    $DOCKER stop homeassistant >/dev/null 2>&1
    sudo python3 "$REPO/home/promover-proxy.py" "$REPO/home/$HA_STORE" >/dev/null 2>&1
    local rc=$?
    $DOCKER start homeassistant >/dev/null 2>&1
    olvidar_estado
    ha_escucha >/dev/null 2>&1
    [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]
}

# Cuando no hay nada que promover (o lo que hay quedo quemado), se borra el
# store para que HA lo regenere desde configuration.yaml en el proximo arranque.
# El archivo se reconstruye solo, pero igual se guarda copia antes.
ha_regenerar_store() {
    $DOCKER stop homeassistant >/dev/null 2>&1
    sudo cp -a "$REPO/home/$HA_STORE" "$REPO/home/$HA_STORE.anterior" 2>/dev/null
    sudo rm -f "$REPO/home/$HA_STORE"
    $DOCKER start homeassistant >/dev/null 2>&1
    olvidar_estado
    ha_escucha >/dev/null 2>&1
}

cfg_homeassistant() {
    esta_arriba homeassistant || return 0

    # Sin el puerto abierto para las redes de Docker, Caddy contesta 502. Va
    # primero porque si no, todo lo de abajo se cae en cadena y el sintoma que
    # ves no se parece en nada a la causa.
    local red
    for red in 172.17.0.0/16 172.18.0.0/16 172.19.0.0/16 172.20.0.0/16; do
        sudo ufw allow from $red to any port 8123 proto tcp >/dev/null 2>&1
    done
    sudo ufw deny 8123/tcp >/dev/null 2>&1

    ha_escucha || { aviso "Home Assistant no contesta todavia"; \
        pendiente "Entrar a http://casa.pi y revisar que levante"; return 1; }

    case "$(ha_por_caddy)" in
        200|302) gris "     Home Assistant ya entraba bien por casa.pi"; return 0 ;;
    esac

    # Intento 1: promover lo que HA haya dejado pendiente.
    if ha_promover; then
        case "$(ha_por_caddy)" in
            200|302)
                ok "Home Assistant: listo en ${B}http://casa.pi${N}"
                gris "     confirme la config del proxy, que si no se revierte sola a los 5 minutos"
                return 0 ;;
        esac
    fi

    # Intento 2: no habia nada usable. Se regenera desde el YAML y se promueve
    # el pendiente nuevo.
    ha_regenerar_store
    if ha_promover; then
        case "$(ha_por_caddy)" in
            200|302)
                ok "Home Assistant: listo en ${B}http://casa.pi${N}"
                gris "     tuve que regenerar su config del proxy, que habia quedado revertida"
                return 0 ;;
        esac
    fi

    aviso "Home Assistant: Caddy llega pero sigue contestando 400"
    gris "     es el rechazo del proxy, y no pude confirmarle la config"
    pendiente "Revisar el bloque http: de home/config/configuration.yaml y volver a correr el instalador"
    return 1
}

# El asistente de bienvenida de Home Assistant, sin navegador.
#
# Home Assistant expone la API que usa su propio frontend para el onboarding, y
# no pide autenticacion justamente porque todavia no hay con que autenticarse.
# Son cuatro pasos y solo el primero lleva datos.
#
# El paso de usuario crea la cuenta de administrador, la enlaza a una persona, y
# de paso crea las areas de la casa (Cocina, Living, Dormitorio...) en el idioma
# que le pases. Con language=es salen en castellano.
#
# La ubicacion NO se toca: es tu casa y no la voy a inventar. La zona horaria ya
# sale bien porque el compose le monta /etc/localtime del host.
ha_onboarding_pendiente() {
    curl -s --max-time 20 http://127.0.0.1:8123/api/onboarding 2>/dev/null \
        | python3 -c '
import sys, json
try:
    pasos = json.load(sys.stdin)
except Exception:
    sys.exit(1)
usuario = next((p for p in pasos if p.get("step") == "user"), None)
sys.exit(1 if usuario is None or usuario.get("done") else 0)' 2>/dev/null
}

cfg_ha_cuenta() {
    local clave="$1"
    esta_arriba homeassistant || return 0
    ha_escucha || return 1

    if ! ha_onboarding_pendiente; then
        gris "     Home Assistant ya tenia su cuenta creada"
        return 0
    fi

    local resp
    resp=$(curl -s --max-time 60 -X POST -H "Content-Type: application/json" \
        -d "{\"name\":\"admin\",\"username\":\"admin\",\"password\":\"$clave\",\"client_id\":\"http://casa.pi/\",\"language\":\"es\"}" \
        http://127.0.0.1:8123/api/onboarding/users 2>/dev/null)

    if ! echo "$resp" | grep -q '"auth_code"'; then
        aviso "Home Assistant: no pude crear el usuario"
        gris "     ${resp:0:120}"
        pendiente "Crear tu usuario entrando a http://casa.pi"
        return 1
    fi

    # Los pasos que siguen quedan para vos, y es a proposito.
    #
    # El de ubicacion abre un mapa para que marques donde vivis. Es la
    # herramienta correcta para eso y no es un dato que yo deba inventar: de ahi
    # salen el amanecer y el atardecer, con los que se dispara media domotica.
    #
    # El de estadisticas de uso es una decision de privacidad. Anotarte en
    # telemetria sin preguntarte estaria mal, asi que te lo deja preguntar a el.
    ok "Home Assistant: usuario ${B}admin${N} creado, entra con tu contrasena de siempre"
    gris "     al entrar te va a pedir la ubicacion en un mapa: eso queda para vos,"
    gris "     es tu casa y de ahi salen el amanecer y el atardecer"
}

# El filtro de noticias lee las credenciales al arrancar. Si se las escribimos
# con el contenedor ya andando, no se entera hasta que alguien lo reinicie.
recrear_filtro_noticias() {
    esta_arriba news-filter || return 0
    $DOCKER compose up -d --force-recreate news-filter >/dev/null 2>&1
    olvidar_estado
    gris "     news-filter reiniciado para que tome las credenciales"
}

# ══════════════════════════════════════════════════════════════════════════════
#  LOS AVISOS
#
#  Dos canales de ntfy. El nombre del canal ES la contrasena: quien lo sabe,
#  recibe. Por eso lo genera el instalador al azar y nunca te lo hace inventar,
#  igual que hace con las API keys de Radarr y Seerr.
#
#  Son dos y no uno para que puedas silenciar el de media sin quedarte ciego al
#  de alertas, y para que el de alertas conserve la propiedad que lo hace util:
#  que si no suena, esta todo bien.
#
#  Van en el .env de la raiz, que nunca se versiona y que respaldo.sh ya
#  levanta solo, porque busca todos los .env del repo.
# ══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════════
#  EL MODULO DE AVISOS
#
#  Es el unico modulo que manda algo FUERA de tu casa, asi que se pregunta y
#  se explica antes de crear nada. El resto del repo no publica un solo byte a
#  internet, y eso deja de ser cierto en cuanto activas esto.
#
#  Y no alcanza con crearlo: suscribirse desde el celular es la unica parte que
#  un script no puede hacer por vos, igual que crear una cuenta. Asi que se
#  guia paso a paso, con los nombres a la vista, en vez de dejarte un ok verde
#  y que despues no sepas que hacer con el.
# ══════════════════════════════════════════════════════════════════════════════

instalar_avisos() {
    local ya; ya=$(leer_var "$REPO/.env" NTFY_ALERTAS 2>/dev/null)

    if [ -z "$ya" ]; then
        echo ""
        info "${B}Que hace:${N} la Pi te manda una notificacion al celular cuando"
        info "algo se rompe. Si no se rompe nada, no te llega nada."
        echo ""
        info "${B}Como:${N} por ntfy, que funciona como un canal de radio. Se elige un"
        info "nombre, la Pi transmite ahi y tu celular escucha. Sin cuenta, sin"
        info "usuario y sin contrasena que crear."
        echo ""
        info "${B}No instala nada en la Pi:${N} ni un programa ni un contenedor."
        echo ""
        aviso "${B}Lo unico que resignas${N}"
        gris "     Los titulos de los avisos pasan por ntfy.sh, un servidor publico"
        gris "     y gratuito de internet. Son textos como \"disco al 91%\"."
        gris "     Es la unica cosa de todo el repo que sale de tu casa."
        echo ""

        if ! preguntar "¿Los activo?" "s"; then
            escribir_var "$REPO/.env" AVISOS no
            info "Listo, no los activo. Todo lo demas sigue igual:"
            gris "     el diagnostico corre igual, el feed de eventos se llena igual,"
            gris "     y Grafana recibe las metricas igual. Solo no te suena el celular."
            echo ""
            gris "     Si cambias de idea:  ./avisos.sh --prender"
            return 0
        fi
        echo ""
    fi

    escribir_var "$REPO/.env" AVISOS si
    cfg_avisos
    guia_suscripcion
}

cfg_avisos() {
    local nuevos=0 t

    if [ -z "$(leer_var "$REPO/.env" NTFY_ALERTAS 2>/dev/null)" ]; then
        t="pi-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
        escribir_var "$REPO/.env" NTFY_ALERTAS "$t"
        nuevos=$((nuevos+1))
    fi

    # Independiente del anterior a proposito: si fuera derivado, conocer el
    # canal de media (que es el que se comparte sin pensar) daria el de alertas.
    if [ -z "$(leer_var "$REPO/.env" NTFY_MEDIA 2>/dev/null)" ]; then
        t="pi-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
        escribir_var "$REPO/.env" NTFY_MEDIA "$t"
        nuevos=$((nuevos+1))
    fi

    # Recargar, porque avisos.sh los leyo al arrancar el script y en la
    # primera corrida todavia no existian.
    NTFY_ALERTAS="$(leer_var "$REPO/.env" NTFY_ALERTAS 2>/dev/null)"
    NTFY_MEDIA="$(leer_var "$REPO/.env" NTFY_MEDIA 2>/dev/null)"

    if [ "$nuevos" -gt 0 ]; then
        ok "$nuevos $(plural "$nuevos" "canal creado" "canales creados"), con nombre al azar"
        gris "     No te los hago inventar a vos: el nombre es la contrasena y"
        gris "     uno pensado por una persona se adivina."
    else
        ok "Los canales ya estaban creados"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  EL GANCHO DE LAS IMPORTACIONES
#
#  Radarr y Sonarr saben ejecutar un script al terminar de importar. Ese script
#  no manda nada: escribe una linea en un archivo compartido con el host, y el
#  host agrupa la tanda y manda UN aviso.
#
#  Asi el nombre del canal nunca entra a un contenedor, y un pack de temporada
#  no son ocho notificaciones seguidas.
#
#  Se arma leyendo el esquema que el propio servicio publica y completandolo,
#  en vez de escribir el JSON a mano: si Radarr agrega un campo obligatorio en
#  una version nueva, esto sigue andando.
# ══════════════════════════════════════════════════════════════════════════════

gancho_puesto() {
    arr_api "$1" "$2" v3 GET /notification 2>/dev/null | grep -q "avisar-import"
}

cfg_gancho_arr() {
    local svc="$1" puerto="$2" nombre="$3" cuerpo

    esta_arriba "$svc" || return 0
    if gancho_puesto "$svc" "$puerto"; then
        ok "$nombre: el gancho de avisos ya estaba"
        return 0
    fi

    cuerpo=$(arr_api "$svc" "$puerto" v3 GET /notification/schema 2>/dev/null | python3 -c '
import sys, json
try:
    esquemas = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for e in esquemas:
    if e.get("implementation") != "CustomScript":
        continue
    e["name"] = "Pi-Services"
    e["onDownload"] = True
    # Las mejoras de calidad llegan al gancho y se filtran en el host, para
    # que la decision viva en ajustes.conf y no haya que recrear nada.
    e["onUpgrade"] = True
    for campo in e.get("fields", []):
        if campo.get("name") == "path":
            campo["value"] = "/scripts/avisar-import.sh"
    print(json.dumps(e))
    break
' 2>/dev/null)

    if [ -z "$cuerpo" ]; then
        aviso "$nombre: no pude leer su esquema de notificaciones"
        pendiente "Enganchar los avisos de $nombre: volve a correr el instalador"
        return 1
    fi

    arr_api "$svc" "$puerto" v3 POST /notification "$cuerpo" >/dev/null 2>&1
    if gancho_puesto "$svc" "$puerto"; then
        ok "$nombre: avisa al celular cuando importa"
    else
        aviso "$nombre: no acepto el gancho"
        gris "     suele ser que /scripts/avisar-import.sh no es ejecutable adentro"
        pendiente "Enganchar los avisos de $nombre a mano en Settings, Connect"
        return 1
    fi
}

# Que Jellyfin reescanee al importar. Sin esto el aviso miente: te dice que ya
# la podes ver y Jellyfin todavia no la indexo.
cfg_rescan_jellyfin() {
    local svc="$1" puerto="$2" nombre="$3" clave cuerpo
    esta_arriba "$svc" || return 0
    esta_arriba jellyfin || return 0

    arr_api "$svc" "$puerto" v3 GET /notification 2>/dev/null | grep -q '"implementation":"MediaBrowser"' && return 0

    clave=$(api_key_jellyfin) || return 0
    [ -n "$clave" ] || return 0

    cuerpo=$(arr_api "$svc" "$puerto" v3 GET /notification/schema 2>/dev/null | CLAVE="$clave" python3 -c '
import sys, json, os
try:
    esquemas = json.load(sys.stdin)
except Exception:
    sys.exit(1)
valores = {"host": "jellyfin", "port": 8096, "apiKey": os.environ["CLAVE"],
           "updateLibrary": True, "useSsl": False}
for e in esquemas:
    if e.get("implementation") != "MediaBrowser":
        continue
    e["name"] = "Jellyfin"
    e["onDownload"] = True
    e["onUpgrade"] = True
    e["onRename"] = True
    for campo in e.get("fields", []):
        if campo.get("name") in valores:
            campo["value"] = valores[campo["name"]]
    print(json.dumps(e))
    break
' 2>/dev/null)

    [ -n "$cuerpo" ] || return 0
    arr_api "$svc" "$puerto" v3 POST /notification "$cuerpo" >/dev/null 2>&1 \
        && ok "$nombre: Jellyfin reescanea al importar"
    return 0
}

cfg_ganchos_media() {
    cfg_gancho_arr radarr 7878 Radarr
    cfg_gancho_arr sonarr 8989 Sonarr
    cfg_rescan_jellyfin radarr 7878 Radarr
    cfg_rescan_jellyfin sonarr 8989 Sonarr
}

# ══════════════════════════════════════════════════════════════════════════════
#  LOS AUTOMATISMOS
#
#  Los timers de systemd y el mensaje de bienvenida estaban en el repo desde
#  siempre y no los instalaba nadie: habia que copiarlos a mano y acordarse.
#  Lo que hay que acordarse de hacer, tarde o temprano no se hace.
#
#  Los horarios NO estan escritos en las unidades: salen de ajustes.conf y se
#  sustituyen aca. Es el mismo principio que los registros DNS del Caddyfile.
#  Cambias una linea en ajustes.conf, corres el instalador, y listo.
# ══════════════════════════════════════════════════════════════════════════════

# Copia un archivo a su lugar del sistema solo si cambio. Devuelve 0 si toco algo.
_instalar_si_cambio() {
    local origen="$1" destino="$2" modo="${3:-644}" tmp
    tmp=$(mktemp)
    sed -e "s|__REPO__|$REPO|g" \
        -e "s|__USUARIO__|$(id -un)|g" \
        -e "s|__CASA__|$HOME|g" \
        -e "s|__DIAGNOSTICO_CADA__|${DIAGNOSTICO_CADA}|g" \
        -e "s|__HORA_RESPALDO__|$(printf '%02d' "${HORA_RESPALDO}")|g" \
        -e "s|__MEDIA_CADA__|${MEDIA_CADA_MIN}|g" \
        "$origen" > "$tmp"
    if sudo cmp -s "$tmp" "$destino" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    sudo cp "$tmp" "$destino" && sudo chmod "$modo" "$destino" && sudo chown root:root "$destino"
    rm -f "$tmp"
    return 0
}

instalar_automatismos() {
    local cambio=0 u

    # Las carpetas en RAM, antes que nada: node-exporter monta una de ellas y
    # si no existe, Docker la crea de root y despues el diagnostico no puede
    # escribir adentro.
    _instalar_si_cambio "$REPO/systemd/pi-services.tmpfiles" /etc/tmpfiles.d/pi-services.conf && cambio=1
    sudo systemd-tmpfiles --create /etc/tmpfiles.d/pi-services.conf >/dev/null 2>&1

    for u in pi-estado pi-respaldo pi-media; do
        _instalar_si_cambio "$REPO/systemd/$u.service" "/etc/systemd/system/$u.service" && cambio=1
        _instalar_si_cambio "$REPO/systemd/$u.timer"   "/etc/systemd/system/$u.timer"   && cambio=1
    done

    # El mensaje de bienvenida del SSH. Es el unico canal que existia antes de
    # los avisos, y sigue siendo util: te muestra lo que esta mal justo en el
    # lugar por el que ya entras.
    if [ -d /etc/update-motd.d ]; then
        _instalar_si_cambio "$REPO/motd/98-pi-services" /etc/update-motd.d/98-pi-services 755 && cambio=1
    fi

    [ "$cambio" = "1" ] && sudo systemctl daemon-reload >/dev/null 2>&1

    local prendidos=0
    for u in pi-estado pi-respaldo; do
        sudo systemctl enable --now "$u.timer" >/dev/null 2>&1 && prendidos=$((prendidos+1))
    done

    # El de media solo tiene sentido si hay avisos: lo unico que hace es
    # mandar la tanda de importaciones al celular. Sin canales seria un
    # temporizador corriendo cada cinco minutos para no hacer nada.
    if avisos_configurados; then
        sudo systemctl enable --now pi-media.timer >/dev/null 2>&1 && prendidos=$((prendidos+1))
    else
        sudo systemctl disable --now pi-media.timer >/dev/null 2>&1
    fi

    if [ "$prendidos" -gt 0 ]; then
        ok "$prendidos $(plural "$prendidos" "tarea programada" "tareas programadas")"
        gris "     diagnostico cada $DIAGNOSTICO_CADA  ·  respaldo a las ${HORA_RESPALDO}:00"
        avisos_configurados && gris "     avisos de peliculas y series cada ${MEDIA_CADA_MIN} min"
        gris "     Los horarios se cambian en ${B}ajustes.conf${N} y se aplican al volver a correr esto."
    else
        aviso "No pude programar las tareas automaticas"
        pendiente "Revisar 'systemctl list-timers pi-*'"
    fi
}

# Las carpetas de datos propios. Se crean ANTES de levantar contenedores: si
# Docker monta una que no existe, la crea el mismo y de root, y despues ni el
# gancho de Radarr ni el diagnostico pueden escribir adentro.
crear_datos() {
    mkdir -p "$DATOS/media-pendiente" 2>/dev/null || return 0
    # Si quedo de root de una corrida vieja, se corrige.
    [ -w "$DATOS/media-pendiente" ] || sudo chown -R "$(id -u):$(id -g)" "$DATOS" 2>/dev/null
    return 0
}

# Las tareas programadas. Va aparte de configurar_servicios porque no depende
# de que modulos hayas elegido: el diagnostico horario y el respaldo diario
# tienen sentido tengas lo que tengas levantado, y no mandan nada afuera.
#
# Los avisos NO estan aca: son un modulo del menu, porque son lo unico que
# sale de tu casa y eso lo decidis vos.
configurar_automatico() {
    titulo "Las tareas programadas"

    info "Ninguna de estas cosas te va a pedir nada nunca mas."
    echo ""

    instalar_automatismos
}

configurar_servicios() {
    local hay=0 mod
    for mod in media monitoring pihole news home; do
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

    # Recien en este punto se sabe si el panel quedo abierto de verdad: o
    # porque TOCAR_CLAVES era 0 y nadie intento ponerla, o porque cfg_pihole
    # fallo. Comprobarlo antes, al final de instalar_pihole, avisaba siempre.
    if [[ " ${SELECCION[*]} " == *" pihole "* ]] && command -v pihole-FTL >/dev/null 2>&1 \
       && ! pihole_tiene_clave; then
        aviso "Pi-hole quedo sin contrasena: su panel es accesible desde tu LAN"
        pendiente "Poner contrasena a Pi-hole:  sudo pihole setpassword"
    fi

    # La clave de API de Pi-hole la necesita el exporter de monitoreo, pero
    # quien la genera es Pi-hole. Va despues de ponerle la contrasena del
    # panel, porque para generarla hay que entrar con ella.
    if [[ " ${SELECCION[*]} " == *" monitoring "* ]]; then
        cfg_pihole_api "$(clave_para 'Pi-hole')"
    fi

    # Antes de crear una sola cuenta, preguntar si las queres creadas.
    preguntar_quien_configura

    # Va antes que los de multimedia porque no depende de ninguno.
    if [[ " ${SELECCION[*]} " == *" home "* ]]; then
        # El proxy se arregla siempre: no es una cuenta, es que casa.pi ande.
        cfg_homeassistant
        if cuenta_automatica homeassistant; then
            cfg_ha_cuenta "$(clave_para 'Home Assistant')"
        else
            pendiente "Crear tu usuario de Home Assistant en http://casa.pi"
        fi
    fi

    if [[ " ${SELECCION[*]} " == *" news "* ]]; then
        local elegidos_news; elegidos_news=$(servicios_elegidos news)
        local toco_noticias=0
        if esta_arriba freshrss && [[ " $elegidos_news " == *" freshrss "* ]]; then
            if cuenta_automatica freshrss; then
                cfg_freshrss "$(clave_para 'FreshRSS')"; toco_noticias=1
            else
                pendiente "Crear tu cuenta de FreshRSS en http://freshrss.pi y habilitar su API"
            fi
        fi
        if esta_arriba wallabag && [[ " $elegidos_news " == *" wallabag "* ]]; then
            if cuenta_automatica wallabag; then
                cfg_wallabag "$(clave_para 'Wallabag')"; toco_noticias=1
            else
                pendiente "Cambiar la contrasena de Wallabag y crear su cliente de API en http://wallabag.pi"
            fi
        fi
        [ "$toco_noticias" = "1" ] && recrear_filtro_noticias
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

        # El perfil de calidad va despues de que los dos existan y tengan
        # carpeta: es lo que Seerr va a elegir al pedir algo.
        cfg_perfil_calidad radarr 7878 Radarr
        cfg_perfil_calidad sonarr 8989 Sonarr
        esta_arriba prowlarr && [[ " $elegidos_media " == *" prowlarr "* ]] && \
            cfg_prowlarr "$(clave_para 'Prowlarr')"
        if esta_arriba bazarr && [[ " $elegidos_media " == *" bazarr "* ]]; then
            cfg_bazarr "$(clave_para 'Bazarr')"
            cfg_bazarr_idiomas
        fi
        if esta_arriba jellyfin && [[ " $elegidos_media " == *" jellyfin "* ]]; then
            if cuenta_automatica jellyfin; then
                cfg_jellyfin "$(clave_para 'Jellyfin')"
            else
                pendiente "Hacer el asistente de Jellyfin en http://jellyfin.pi y crear las dos bibliotecas"
            fi
        fi

        # Seerr va ULTIMO: necesita las API keys de los dos *arr, el perfil de
        # calidad ya creado, y Jellyfin con su usuario andando.
        if esta_arriba seerr && [[ " $elegidos_media " == *" seerr "* ]]; then
            if cuenta_automatica seerr; then
                cfg_seerr "$(clave_para 'Seerr')"
            else
                pendiente "Entrar a http://seerr.pi con tu usuario de Jellyfin y conectar Radarr y Sonarr"
            fi
        fi

        # El gancho de las importaciones va despues de Jellyfin, porque para
        # pedirle el reescaneo hace falta su clave, y esa solo existe una vez
        # que Jellyfin tiene usuario.
        #
        # Y solo si hay avisos: sin canal, el gancho escribiria en un archivo
        # que nadie lee nunca.
        avisos_configurados && cfg_ganchos_media

        # Con las claves ya disponibles, los recuadros de la homepage pasan
        # de ser un enlace a mostrar datos en vivo.
        cfg_homepage_widgets

        if [ "$MEDIA_MODO" = "pausa" ]; then
            echo ""
            aviso "Las descargas quedaron ${B}en pausa${N} a proposito."
            gris "     Podes cargar indexers y agregar peliculas sin riesgo: se van a"
            gris "     encolar, pero no se baja nada hasta que conectes el disco y las"
            gris "     despauses desde http://qbit.pi."
        fi
    fi
}

