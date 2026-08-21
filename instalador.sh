#!/bin/bash
# ==============================================================================
#  instalador.sh  ·  Instalador por modulos de Pi-Services
#
#  Corrélo parado en la raiz del repo:   ./instalador.sh
#
#  No es un script lineal: mira el estado real del equipo y se adapta.
#  Podes correrlo la primera vez con dos modulos, y volver en un mes a
#  agregar un tercero. Detecta lo que ya esta hecho y no lo repite.
#
#  Documentacion completa:  docs/INSTALADOR.md
# ==============================================================================

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

MODULOS=(sistema pihole core monitoring news finance fitbit media ofelia calibre tailscale seguridad)

declare -A NOMBRE=(
  [sistema]="Base del sistema"
  [pihole]="Pi-hole  ·  DNS y bloqueo de publicidad"
  [core]="Caddy y Homepage  ·  la puerta de entrada"
  [monitoring]="Monitoreo  ·  Grafana y Prometheus"
  [news]="Noticias  ·  FreshRSS, Wallabag y el filtro"
  [finance]="Finanzas  ·  lector de mails del banco"
  [fitbit]="Fitbit  ·  datos de salud"
  [media]="Multimedia  ·  Jellyfin, Radarr, Prowlarr, Bazarr, qBittorrent"
  [ofelia]="Ofelia  ·  programador de tareas"
  [calibre]="Calibre  ·  biblioteca de libros"
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
  [calibre]="Servidor de libros con ingesta automatica. Va nativo, no en Docker."
  [tailscale]="Entras a tus servicios desde afuera de casa sin abrir puertos. Tambien te da SSH de emergencia si Docker se rompe."
  [seguridad]="Cierra todo salvo lo necesario y banea intentos de fuerza bruta."
)

declare -A SERVICIOS=(
  [core]="caddy homepage"
  [monitoring]="grafana prometheus node-exporter pihole-exporter"
  [news]="freshrss wallabag news-filter news-filter-ui"
  [finance]="itau-email-tracker finance-tracker-ui"
  [fitbit]="fitbit-exporter fitbit-exporter-ui"
  [media]="jellyfin qbittorrent prowlarr radarr bazarr"
  [ofelia]="ofelia"
)

declare -A NATIVO=( [sistema]=1 [pihole]=1 [calibre]=1 [tailscale]=1 [seguridad]=1 )

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
  [bazarr]="Descarga subtitulos"
  [ofelia]="Programador de tareas"
)

# Servicios que no sirven de nada sin otro. Formato: servicio|de que depende|por que
DEPENDENCIAS=(
  "news-filter|freshrss wallabag|lee de FreshRSS y guarda en Wallabag"
  "news-filter-ui|news-filter|es el panel del filtro"
  "radarr|prowlarr qbittorrent|Prowlarr le da los indexers y qBittorrent descarga"
  "bazarr|radarr|toma de Radarr que peliculas subtitular"
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
"core|caddy/.env|CADDY_PASSWORD_HASH|hash|Contrasena de homepage, prometheus y calibre|La eligis vos ahora"
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

# Cuenta contenedores de un modulo que estan corriendo
corriendo() {
    local mod="$1" n=0 s
    for s in ${SERVICIOS[$mod]:-}; do
        $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$s" && n=$((n+1))
    done
    echo "$n"
}

total_servicios() {
    local mod="$1"; echo "${SERVICIOS[$mod]:-}" | wc -w
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

    if systemctl --user is-active calibre-server >/dev/null 2>&1; then
        ESTADO[calibre]=activo; DETALLE[calibre]="servidor corriendo en el 8083"
    elif command -v calibre-server >/dev/null 2>&1; then
        ESTADO[calibre]=parcial; DETALLE[calibre]="instalado pero el servicio no arranca"
    else
        ESTADO[calibre]=inactivo; DETALLE[calibre]="no instalado"
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

        if [ "$arriba" -eq "$total" ] && [ "$faltan" -eq 0 ]; then
            ESTADO[$mod]=activo; DETALLE[$mod]="$arriba de $total contenedores arriba"
        elif [ "$arriba" -eq "$total" ] && [ "$faltan" -gt 0 ]; then
            ESTADO[$mod]=parcial; DETALLE[$mod]="$arriba de $total arriba, pero faltan $faltan datos"
        elif [ "$arriba" -gt 0 ]; then
            ESTADO[$mod]=parcial; DETALLE[$mod]="solo $arriba de $total contenedores arriba"
        else
            ESTADO[$mod]=inactivo
            [ "$faltan" -gt 0 ] && DETALLE[$mod]="sin levantar, faltan $faltan datos" || DETALLE[$mod]="sin levantar"
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
#  PANTALLAS
# ══════════════════════════════════════════════════════════════════════════════

portada() {
    clear
    cat <<'EOF'
  ╔════════════════════════════════════════════════════════════════╗
  ║              Pi-Services  ·  Instalador por modulos            ║
  ╚════════════════════════════════════════════════════════════════╝
EOF
    echo ""
    echo "  Este instalador mira el estado real de tu equipo y se adapta."
    echo "  Podes correrlo hoy con dos modulos y volver manana a sumar otro:"
    echo "  detecta lo que ya esta hecho y no lo repite."
    echo ""
    echo "  Nunca vas a tener que copiar y pegar comandos: si hace falta un"
    echo "  dato, te lo pide. Y si no lo tenes a mano, lo salteas y seguis."
    echo ""
}

diagnostico() {
    titulo "Estado actual"
    local mod
    for mod in "${MODULOS[@]}"; do
        printf "  %s  %-56s %s\n" "$(icono "${ESTADO[$mod]}")" "${NOMBRE[$mod]}" "$(etiqueta "${ESTADO[$mod]}")"
        [ -n "${DETALLE[$mod]:-}" ] && gris "     ${DETALLE[$mod]}"
    done
    echo ""
    gris "  ● funcionando    ◐ incompleto    ○ sin instalar"
}

# Imprime una lista de variables faltantes, agrupadas por modulo
listar_faltantes() {
    local mod_previo="" linea m arch v tipo desc ayuda
    for linea in "$@"; do
        IFS='|' read -r m arch v tipo desc ayuda <<< "$linea"
        if [ "$m" != "$mod_previo" ]; then
            echo ""
            echo "  ${B}${NOMBRE[$m]}${N}"
            mod_previo="$m"
        fi
        echo "     ${C}·${N} $desc"
        if [ "$tipo" = "archivo" ]; then
            gris "         es el archivo:  $arch"
        else
            gris "         va en:  $arch  ->  $v="
        fi
        [ -n "$ayuda" ] && gris "         donde:  $ayuda"
    done
}

# Detalle de que datos faltan, separando lo que ya esta corriendo de lo que no.
# Lo que corre con datos faltantes es lo urgente: el servicio esta ahi pero
# no puede hacer su trabajo.
faltantes_detallado() {
    local corriendo_falta=() apagado_falta=()
    local linea m arch v tipo desc ayuda

    for linea in "${VARIABLES[@]}"; do
        IFS='|' read -r m arch v tipo desc ayuda <<< "$linea"
        [ "$tipo" = "auto" ] && continue
        completa "$arch" "$v" && continue
        if [ "$(corriendo "$m")" -gt 0 ]; then
            corriendo_falta+=("$linea")
        else
            apagado_falta+=("$linea")
        fi
    done

    # Los archivos se reportan igual que las variables, en el mismo formato
    local ruta como plantilla marcador
    for linea in "${ARCHIVOS[@]}"; do
        IFS='|' read -r m ruta desc como plantilla marcador <<< "$linea"
        archivo_completo "$ruta" "$marcador" && continue
        local fila="$m|$ruta|(archivo)|archivo|$desc|$como"
        if [ "$(corriendo "$m")" -gt 0 ]; then
            corriendo_falta+=("$fila")
        else
            apagado_falta+=("$fila")
        fi
    done

    [ ${#corriendo_falta[@]} -eq 0 ] && [ ${#apagado_falta[@]} -eq 0 ] && {
        echo ""
        ok "No falta ningun dato. Todo lo que tenes levantado esta completo."
        return 0
    }

    if [ ${#corriendo_falta[@]} -gt 0 ]; then
        titulo "Datos que faltan en lo que ya tenes levantado"
        aviso "Estos servicios estan corriendo pero no pueden hacer su trabajo"
        info "hasta que cargues estos datos."
        listar_faltantes "${corriendo_falta[@]}"
    fi

    if [ ${#apagado_falta[@]} -gt 0 ]; then
        echo ""
        titulo "Datos que van a hacer falta si levantas estos modulos"
        listar_faltantes "${apagado_falta[@]}"
    fi

    echo ""
    info "Elegi el modulo correspondiente en el menu y te los voy pidiendo de a uno."
}

# ══════════════════════════════════════════════════════════════════════════════
#  SELECCION
# ══════════════════════════════════════════════════════════════════════════════

SELECCION=()

menu() {
    titulo "Que queres instalar o completar"

    local i=1 mod
    declare -ga INDICE=()
    for mod in "${MODULOS[@]}"; do
        INDICE+=("$mod")
        local marca=""
        [[ " $REQUERIDOS " == *" $mod "* ]] && marca=" ${A}(necesario)${N}"
        printf "  ${B}%2d${N})  %s  %-52s %s%s\n" "$i" "$(icono "${ESTADO[$mod]}")" "${NOMBRE[$mod]}" "$(etiqueta "${ESTADO[$mod]}")" "$marca"
        i=$((i+1))
    done

    echo ""
    info "Escribi los numeros separados por espacio.  Ejemplo:  1 2 3 5"
    info "O escribi:  ${B}todo${N}  ·  ${B}faltantes${N} (solo lo incompleto o sin instalar)"
    echo ""
    local resp
    read -r -p "  ${B}Tu eleccion:${N} " resp </dev/tty

    SELECCION=()
    if [ "$resp" = "todo" ]; then
        SELECCION=("${MODULOS[@]}")
    elif [ "$resp" = "faltantes" ]; then
        for mod in "${MODULOS[@]}"; do
            [ "${ESTADO[$mod]}" != "activo" ] && SELECCION+=("$mod")
        done
    else
        local n
        for n in $resp; do
            if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#INDICE[@]}" ]; then
                SELECCION+=("${INDICE[$((n-1))]}")
            fi
        done
    fi

    # Dependencias implicitas
    local mod2 tiene_docker=0
    for mod2 in "${SELECCION[@]}"; do
        [ -n "${SERVICIOS[$mod2]:-}" ] && tiene_docker=1
    done
    if [ "$tiene_docker" = "1" ] && [[ ! " ${SELECCION[*]} " == *" sistema "* ]] && [ "${ESTADO[sistema]}" != "activo" ]; then
        aviso "Agrego 'Base del sistema': hace falta Docker para los modulos que elegiste."
        SELECCION=(sistema "${SELECCION[@]}")
    fi
    if [ "$tiene_docker" = "1" ] && [[ ! " ${SELECCION[*]} " == *" core "* ]] && [ "${ESTADO[core]}" != "activo" ]; then
        aviso "Agrego 'Caddy y Homepage': sin eso no entras a ningun servicio por su nombre."
        SELECCION=("${SELECCION[@]}" core)
    fi

    if [ ${#SELECCION[@]} -eq 0 ]; then
        echo ""; falla "No elegiste nada."; exit 0
    fi

    echo ""
    ok "Vas a instalar o completar:"
    for mod in "${SELECCION[@]}"; do info "· ${NOMBRE[$mod]}"; done
    echo ""
    preguntar "¿Seguimos?" "s" || exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  ELECCION DE SERVICIOS SUELTOS
#
#  Un modulo agrupa varios contenedores, pero no estas obligado a levantarlos
#  todos. Aca podes elegir de a uno.
# ══════════════════════════════════════════════════════════════════════════════

declare -A ELEGIDOS

# Que servicios del modulo hay que levantar (los elegidos, o todos por defecto)
servicios_elegidos() {
    local mod="$1"
    echo "${ELEGIDOS[$mod]:-${SERVICIOS[$mod]:-}}"
}

avisar_dependencias() {
    local elegidos="$1" linea srv deps motivo faltan d
    for linea in "${DEPENDENCIAS[@]}"; do
        IFS='|' read -r srv deps motivo <<< "$linea"
        [[ " $elegidos " == *" $srv "* ]] || continue
        faltan=""
        for d in $deps; do
            # Si no lo elegiste y tampoco esta corriendo, falta
            if [[ " $elegidos " != *" $d "* ]] && ! $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$d"; then
                faltan="$faltan $d"
            fi
        done
        if [ -n "$faltan" ]; then
            aviso "${B}$srv${N} necesita:${B}$faltan${N}"
            gris "     $motivo"
        fi
    done
}

elegir_servicios() {
    local hay_multiples=0 mod
    for mod in "${SELECCION[@]}"; do
        [ "$(total_servicios "$mod")" -gt 1 ] && hay_multiples=1
    done
    [ "$hay_multiples" = "1" ] || return 0

    titulo "Servicios sueltos"

    info "Algunos modulos agrupan varios contenedores. Podes levantarlos todos"
    info "o elegir solo los que quieras."
    echo ""

    if preguntar "¿Levantar todos los servicios de cada modulo elegido?" "s"; then
        ok "Se levantan completos"
        return 0
    fi

    echo ""
    for mod in "${SELECCION[@]}"; do
        local todos; todos="${SERVICIOS[$mod]:-}"
        [ -n "$todos" ] || continue
        [ "$(echo "$todos" | wc -w)" -gt 1 ] || { ELEGIDOS[$mod]="$todos"; continue; }

        echo "  ${B}${NOMBRE[$mod]}${N}"
        local i=1 s
        declare -a lista=()
        for s in $todos; do
            lista+=("$s")
            local marca="${G}○${N}"
            $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$s" && marca="${V}●${N}"
            printf "     ${B}%d${N}) %s %-22s ${G}%s${N}\n" "$i" "$marca" "$s" "${QUE_HACE[$s]:-}"
            i=$((i+1))
        done
        echo ""
        local resp
        read -r -p "     ${B}Cuales${N} (numeros, o Enter para todos): " resp </dev/tty
        if [ -z "$resp" ]; then
            ELEGIDOS[$mod]="$todos"
            ok "Todos"
        else
            local sel="" n
            for n in $resp; do
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#lista[@]}" ]; then
                    sel="$sel ${lista[$((n-1))]}"
                fi
            done
            sel="${sel# }"
            if [ -z "$sel" ]; then
                aviso "No entendi, levanto todos"
                ELEGIDOS[$mod]="$todos"
            else
                ELEGIDOS[$mod]="$sel"
                ok "Elegidos: $sel"
                avisar_dependencias "$sel"
            fi
        fi
        echo ""
    done
}

# ══════════════════════════════════════════════════════════════════════════════
#  RECOLECCION DE VARIABLES
# ══════════════════════════════════════════════════════════════════════════════

# Los .env de TODOS los modulos tienen que existir, aunque no los uses:
# Docker Compose falla al leer la configuracion si falta uno solo.
crear_envs_vacios() {
    local linea m arch v _
    for linea in "${VARIABLES[@]}"; do
        IFS='|' read -r m arch v _ _ _ <<< "$linea"
        mkdir -p "$(dirname "$arch")"
        [ -f "$arch" ] || touch "$arch"
    done
    [ -f news/freshrss/.env ] || { mkdir -p news/freshrss; touch news/freshrss/.env; }
    [ -f news/news-filter/.env ] || cp news/news-filter/.env.example news/news-filter/.env 2>/dev/null
    mkdir -p fitbit-exporter/exports finance/finance-tracker/data news/news-filter/data
}

valor_automatico() {
    case "$2" in
        CADDY_USER|UI_USERNAME)        echo "admin" ;;
        PI_IP)                         echo "$IP_FIJA" ;;
        SECRET_KEY)                    python3 -c 'import secrets;print(secrets.token_hex(32))' ;;
        FITBIT_EXPORTS_PATH)           echo "$REPO/fitbit-exporter/exports" ;;
        FINANCE_DATA_PATH)             echo "$REPO/finance/finance-tracker/data" ;;
        PUID)                          id -u ;;
        PGID)                          id -g ;;
        TZ)                            timedatectl show -p Timezone --value ;;
        JELLYFIN_PublishedServerUrl)   echo "http://jellyfin.pi" ;;
        QBIT_TORRENT_PORT)             echo "6881" ;;
        DAS_ROOT)                      echo "/mnt/das" ;;
        *)                             echo "" ;;
    esac
}

INCOMPLETOS=()

recolectar() {
    titulo "Datos que hacen falta"

    crear_envs_vacios
    crear_archivos_faltantes

    # Los archivos de token no se pueden pedir por consola: salen de un flujo
    # de autorizacion en el navegador. Se avisan como pendientes.
    local la m ruta desc como plantilla marcador
    for la in "${ARCHIVOS[@]}"; do
        IFS='|' read -r m ruta desc como plantilla marcador <<< "$la"
        [[ " ${SELECCION[*]} " == *" $m "* ]] || continue
        archivo_completo "$ruta" "$marcador" && continue
        INCOMPLETOS+=("$m|$ruta|(archivo)|$desc|$como")
    done

    # Primero los automaticos, sin molestar al usuario
    local linea m arch v tipo desc ayuda auto=0
    for linea in "${VARIABLES[@]}"; do
        IFS='|' read -r m arch v tipo desc ayuda <<< "$linea"
        [[ " ${SELECCION[*]} " == *" $m "* ]] || continue
        [ "$tipo" = "auto" ] || continue
        if ! completa "$arch" "$v"; then
            escribir_var "$arch" "$v" "$(valor_automatico "$arch" "$v")"
            auto=$((auto+1))
        fi
    done
    [ "$auto" -gt 0 ] && ok "Complete $auto valores automaticos (rutas, IP, usuario, zona horaria, claves de sesion)"

    # Ahora los que necesitan al usuario
    local faltantes=()
    for linea in "${VARIABLES[@]}"; do
        IFS='|' read -r m arch v tipo desc ayuda <<< "$linea"
        [[ " ${SELECCION[*]} " == *" $m "* ]] || continue
        [ "$tipo" = "auto" ] && continue
        completa "$arch" "$v" && continue
        faltantes+=("$linea")
    done

    if [ ${#faltantes[@]} -eq 0 ]; then
        echo ""; ok "No falta ningun dato. Todo lo necesario ya estaba cargado."
        return
    fi

    # Las contrasenas salen todas de la misma, asi que se pregunta una sola vez
    # antes del recorrido y despues no se vuelve a molestar con ninguna.
    local claves=0 otros=0
    for linea in "${faltantes[@]}"; do
        IFS='|' read -r _ _ _ tipo _ _ <<< "$linea"
        case "$tipo" in clave|hash) claves=$((claves+1)) ;; *) otros=$((otros+1)) ;; esac
    done
    [ "$claves" -gt 0 ] && pedir_clave_maestra

    echo ""
    if [ "$otros" -eq 0 ]; then
        info "Con la contrasena alcanza: los otros $claves campos salen de ahi."
    else
        info "Te voy a pedir ${B}$otros${N} datos mas, de a uno."
        info "Si alguno no lo tenes a mano, apreta Enter y seguimos: el modulo se"
        info "instala igual y al final te digo exactamente que quedo sin completar."
    fi
    echo ""

    local i=1 total=${#faltantes[@]}
    for linea in "${faltantes[@]}"; do
        IFS='|' read -r m arch v tipo desc ayuda <<< "$linea"
        echo "  ${B}[$i/$total]${N} ${C}${desc}${N}"
        gris "        modulo: ${NOMBRE[$m]}"
        gris "        archivo: $arch  ·  variable: $v"
        [ -n "$ayuda" ] && echo "        ${A}$ayuda${N}"

        local valor=""
        case "$tipo" in
            clave|hash)
                valor=$(clave_para "$desc")
                gris "        uso la contrasena que elegiste"
                ;;
            *)
                read -r -p "        ${B}valor${N} (Enter para saltear): " valor </dev/tty
                ;;
        esac

        if [ -z "$valor" ]; then
            aviso "Salteado"
            INCOMPLETOS+=("$m|$arch|$v|$desc|$ayuda")
        elif [ "$tipo" = "hash" ]; then
            info "Generando el hash, bcrypt es lento a proposito..."
            local hash
            hash=$($DOCKER run --rm caddy:2-alpine caddy hash-password --plaintext "$valor" 2>/dev/null)
            if [ -n "$hash" ]; then
                # Cada $ va duplicado o Docker Compose lo toma por variable
                escribir_var "$arch" "$v" "${hash//\$/\$\$}"
                ok "Guardado"
            else
                falla "No se pudo generar el hash. ¿Docker esta corriendo?"
                INCOMPLETOS+=("$m|$arch|$v|$desc|$ayuda")
            fi
            unset hash
        else
            escribir_var "$arch" "$v" "$valor"
            ok "Guardado"
        fi
        unset valor
        echo ""
        i=$((i+1))
    done
}

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALACION
# ══════════════════════════════════════════════════════════════════════════════

instalar_sistema() {
    [ "${ESTADO[sistema]}" = "activo" ] && { ok "Ya estaba listo"; return; }

    sudo timedatectl set-timezone "$(timedatectl show -p Timezone --value)" 2>/dev/null
    sudo tune2fs -c 30 "$(findmnt -no SOURCE /)" >/dev/null 2>&1
    ok "Chequeo del disco cada 30 arranques"
    gris "     Viene desactivado de fabrica, y por eso un sistema de archivos"
    gris "     danado puede degradarse meses sin que nadie se entere."

    if ! command -v docker >/dev/null 2>&1; then
        info "Instalando Docker..."
        curl -fsSL https://get.docker.com | sudo sh >/dev/null 2>&1
        sudo usermod -aG docker "$USER"
        sudo systemctl enable --now docker >/dev/null 2>&1
        ok "Docker instalado"
    else
        ok "Docker ya estaba"
    fi

    if ! systemctl is-enabled log2ram >/dev/null 2>&1; then
        info "Instalando log2ram (mantiene los logs en RAM)..."
        curl -fsSL https://azlux.fr/repo.gpg | sudo tee /usr/share/keyrings/azlux-archive-keyring.gpg >/dev/null 2>&1
        echo "deb [signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] http://packages.azlux.fr/debian/ stable main" \
            | sudo tee /etc/apt/sources.list.d/azlux.list >/dev/null
        sudo apt-get update -qq 2>/dev/null
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y log2ram >/dev/null 2>&1
        sudo sed -i 's|^SIZE=.*|SIZE=512M|' /etc/log2ram.conf 2>/dev/null
        ok "log2ram instalado"
        pendiente "Reiniciar para que log2ram tome efecto"
    fi
}

# ── Listas de bloqueo ─────────────────────────────────────────────────────────
#
#  HaGeZi publica varias listas, de menos a mas agresiva. Cuanto mas estricta,
#  mas cosas bloquea, y tambien mas chances de romper algo legitimo.

BL_BASE="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock"

elegir_blocklists() {
    local actuales
    actuales=$(sudo pihole-FTL sqlite3 /etc/pihole/gravity.db 'SELECT COUNT(*) FROM adlist WHERE enabled=1;' 2>/dev/null)
    local dominios
    dominios=$(sudo pihole-FTL sqlite3 /etc/pihole/gravity.db 'SELECT COUNT(*) FROM gravity;' 2>/dev/null)

    echo ""
    info "${B}Listas de bloqueo${N}"
    gris "     Ahora tenes ${actuales:-0} listas activas y ${dominios:-0} dominios bloqueados."
    echo ""

    if [ "${dominios:-0}" -gt 1000 ] 2>/dev/null; then
        preguntar "¿Queres cambiar o agregar listas?" "n" || { ok "Se dejan como estan"; return; }
    fi

    echo "     HaGeZi publica varias, de menos a mas agresiva:"
    echo ""
    echo "     ${B}1${N})  Light        ~60.000 dominios   lo minimo, no rompe nada"
    echo "     ${B}2${N})  Multi        ~180.000           equilibrio para el dia a dia"
    echo "     ${B}3${N})  Pro          ~250.000           agrega rastreo y telemetria"
    echo "     ${B}4${N})  Pro++        ~300.000           suma telemetria de sistemas operativos"
    echo "     ${B}5${N})  Ultimate     ~365.000           la mas estricta que hay"
    echo "     ${B}6${N})  Otra URL     pegas la que quieras"
    echo "     ${B}7${N})  Ninguna      dejar solo la que Pi-hole trae de fabrica"
    echo ""
    aviso "Cuanto mas estricta, mas chances de que algo legitimo deje de andar."
    gris "     Si algo se rompe, se arregla desde el panel: Domains, Add to allowlist."
    echo ""

    local resp
    read -r -p "     ${B}Cual${N} (numeros separados por espacio): " resp </dev/tty
    [ -z "$resp" ] && { ok "Sin cambios"; return; }

    local agregadas=0 n url nombre
    for n in $resp; do
        url=""; nombre=""
        case "$n" in
            1) url="$BL_BASE/light.txt";     nombre="HaGeZi Light" ;;
            2) url="$BL_BASE/multi.txt";     nombre="HaGeZi Multi" ;;
            3) url="$BL_BASE/pro.txt";       nombre="HaGeZi Pro" ;;
            4) url="$BL_BASE/pro.plus.txt";  nombre="HaGeZi Pro++" ;;
            5) url="$BL_BASE/ultimate.txt";  nombre="HaGeZi Ultimate" ;;
            6)
                read -r -p "     ${B}URL de la lista:${N} " url </dev/tty
                [ -z "$url" ] && continue
                nombre="Lista propia"
                ;;
            7) ok "Se deja solo la lista de fabrica"; return ;;
            *) continue ;;
        esac

        # Verifico que la URL responda antes de meterla en la base
        local codigo
        codigo=$(curl -sI --max-time 20 "$url" 2>/dev/null | head -1 | grep -oE "[0-9]{3}")
        if [ "$codigo" != "200" ]; then
            falla "$nombre no responde (HTTP ${codigo:-sin respuesta}), la salteo"
            continue
        fi

        printf "INSERT OR IGNORE INTO adlist (address, enabled, comment) VALUES ('%s', 1, '%s');\n" "$url" "$nombre" \
            | sudo pihole-FTL sqlite3 /etc/pihole/gravity.db 2>/dev/null
        ok "Agregada: $nombre"
        agregadas=$((agregadas+1))
    done

    # Dominios sueltos que quieras bloquear a mano
    echo ""
    if preguntar "¿Queres bloquear algun sitio puntual? (por ejemplo redes sociales)" "n"; then
        info "Escribi un dominio por vez. Enter vacio para terminar."
        while true; do
            local d
            read -r -p "     ${B}dominio${N} (Enter para terminar): " d </dev/tty
            [ -z "$d" ] && break
            # Regex para que agarre el dominio y todos sus subdominios
            local limpio="${d#www.}"
            printf "INSERT OR IGNORE INTO domainlist (type, domain, enabled, comment) VALUES (3, '(\\.|^)%s\$', 1, 'Bloqueado a mano');\n" \
                "${limpio//./\\.}" | sudo pihole-FTL sqlite3 /etc/pihole/gravity.db 2>/dev/null
            ok "Bloqueado: $limpio y sus subdominios"
        done
    fi

    if [ "$agregadas" -gt 0 ] || [ "${dominios:-0}" -lt 1000 ]; then
        info "Descargando las listas, tarda unos minutos..."
        sudo pihole -g >/dev/null 2>&1
        ok "$(sudo pihole-FTL sqlite3 /etc/pihole/gravity.db 'SELECT COUNT(*) FROM gravity;' 2>/dev/null) dominios bloqueados"
    fi
}

instalar_pihole() {
    if [ "${ESTADO[pihole]}" = "activo" ]; then
        ok "Ya estaba funcionando"
        elegir_blocklists
        return
    fi

    if ! command -v pihole >/dev/null 2>&1; then
        info "Instalando Pi-hole..."
        sudo mkdir -p /etc/pihole
        sudo tee /etc/pihole/setupVars.conf >/dev/null <<EOF
PIHOLE_INTERFACE=eth0
IPV4_ADDRESS=$IP_FIJA/$MASCARA
PIHOLE_DNS_1=9.9.9.9
PIHOLE_DNS_2=149.112.112.112
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=false
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=false
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=local
BLOCKING_ENABLED=true
WEBPASSWORD=
EOF
        curl -sSL https://install.pi-hole.net | sudo bash /dev/stdin --unattended
        ok "Pi-hole instalado"
    fi

    # Liberar el 80 para Caddy
    if sudo pihole-FTL --config webserver.port 2>/dev/null | grep -q "^80o"; then
        sudo pihole-FTL --config webserver.port "8181o,[::]:8181o" >/dev/null
        sudo systemctl restart pihole-FTL
        ok "Panel movido al 8181, el 80 queda libre para Caddy"
    fi

    # Registros DNS de los servicios
    local H="["
    local s
    for s in homepage grafana wallabag freshrss news finance prometheus pihole fitbit calibre jellyfin radarr prowlarr bazarr qbit; do
        H="$H\"$IP_FIJA $s.pi\","
    done
    sudo pihole-FTL --config dns.hosts "${H%,}]" >/dev/null 2>&1
    sudo systemctl restart pihole-FTL
    ok "15 registros DNS cargados (los nombres *.pi)"

    elegir_blocklists

    if [ -z "$(sudo pihole-FTL --config webserver.api.pwhash 2>/dev/null | tr -d '"')" ]; then
        aviso "Pi-hole quedo sin contrasena: su panel es accesible desde tu LAN"
        pendiente "Poner contrasena a Pi-hole:  sudo pihole setpassword"
    fi
}

# Baja las imagenes de a una. En paralelo satura la SD y se cuelga sin dar
# error, dejando capas escritas a medias que despues rompen contenedores.
bajar_imagenes() {
    local img imgs
    imgs=$($DOCKER compose config 2>/dev/null | grep -oE '^\s+image: .*' | awk '{print $2}' | sort -u)
    for img in $imgs; do
        if ! $DOCKER image inspect "$img" >/dev/null 2>&1; then
            info "bajando $img"
            $DOCKER pull "$img" >/dev/null 2>&1 || aviso "fallo la descarga de $img"
        fi
    done
}

levantar_modulo() {
    local mod="$1"
    local servicios; servicios=$(servicios_elegidos "$mod")
    [ -n "$servicios" ] || return 0

    # La red tiene que existir ANTES. Tres composes la declaran como externa
    # porque estan pensados para correr sueltos; si no existe, el up construye
    # todo durante una hora y recien al final falla sin levantar nada.
    if ! $DOCKER network ls --format '{{.Name}}' 2>/dev/null | grep -qx "pi-services"; then
        $DOCKER network create pi-services >/dev/null 2>&1
        ok "Red 'pi-services' creada"
    fi

    # Los que ya estan corriendo no se tocan
    local pendientes="" s
    for s in $servicios; do
        if $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$s"; then
            gris "     $s ya estaba arriba, no lo toco"
        else
            pendientes="$pendientes $s"
        fi
    done
    pendientes="${pendientes# }"

    if [ -z "$pendientes" ]; then
        ok "Todos los servicios elegidos ya estaban arriba"
        return 0
    fi

    info "Levantando: $pendientes"
    # shellcheck disable=SC2086
    $DOCKER compose up -d $pendientes 2>&1 | grep -viE "^\s*$" | tail -6 | sed 's/^/      /'

    sleep 4
    local arriba=0 total=0
    for s in $servicios; do
        total=$((total+1))
        $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$s" && arriba=$((arriba+1))
    done
    if [ "$arriba" -eq "$total" ]; then
        ok "$arriba de $total contenedores arriba"
    else
        aviso "$arriba de $total arriba"
        for s in $servicios; do
            $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$s" || \
                gris "     no levanto: $s   ·   ver con: docker compose logs $s"
        done
        pendiente "Revisar los contenedores de ${NOMBRE[$mod]} que no levantaron"
    fi
}

instalar_calibre() {
    if [ "${ESTADO[calibre]}" = "activo" ]; then ok "Ya estaba funcionando"; return; fi
    if ! command -v calibre-server >/dev/null 2>&1; then
        info "Instalando Calibre (baja bastantes dependencias)..."
        (cd "$REPO/calibre" && ./install.sh) 2>&1 | tail -3 | sed 's/^/      /'
    fi
    # Su install.sh no puede terminar por SSH: le falta la sesion de usuario
    # para hablar con systemd, y deja los servicios instalados pero apagados.
    sudo loginctl enable-linger "$USER" 2>/dev/null
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    systemctl --user daemon-reload 2>/dev/null
    systemctl --user enable --now calibre-server 2>/dev/null
    systemctl --user enable --now calibre-ingest.timer 2>/dev/null
    sleep 4
    if systemctl --user is-active calibre-server >/dev/null 2>&1; then
        ok "Calibre corriendo en el 8083"
    else
        aviso "No arranco"
        pendiente "Revisar Calibre:  systemctl --user status calibre-server"
    fi
}

instalar_tailscale() {
    if [ "${ESTADO[tailscale]}" = "activo" ]; then ok "Ya estaba conectado"; return; fi
    command -v tailscale >/dev/null 2>&1 || { info "Instalando..."; curl -fsSL https://tailscale.com/install.sh | sudo sh >/dev/null 2>&1; }
    echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-tailscale.conf >/dev/null
    echo "net.ipv6.conf.all.forwarding = 1" | sudo tee -a /etc/sysctl.d/99-tailscale.conf >/dev/null
    sudo sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null 2>&1
    echo ""
    aviso "Te va a mostrar una URL: abrila en el navegador y autoriza el equipo."
    echo ""
    sudo tailscale up --advertise-routes="${IP_FIJA%.*}.0/$MASCARA" --accept-dns=false </dev/tty
    echo ""
    aviso "Faltan 3 pasos en login.tailscale.com que no se pueden hacer desde aca:"
    info "1. Machines, tu Pi, Edit route settings, aprobar la ruta"
    info "2. DNS, Add nameserver, custom, $IP_FIJA"
    info "3. DNS, activar 'Override DNS servers'"
    info "Sin eso, el celular no usa Pi-hole cuando estas fuera de casa."
    pendiente "Aprobar la ruta y el DNS en login.tailscale.com (3 pasos)"
}

instalar_seguridad() {
    if [ "${ESTADO[seguridad]}" = "activo" ]; then ok "Ya estaba activo"; return; fi

    aviso "Este paso puede dejarte sin SSH si algo sale mal."
    info "Por eso activo una red de seguridad: si en 4 minutos no confirmas"
    info "que seguis entrando, el firewall se apaga solo."
    echo ""
    preguntar "¿Seguimos?" "s" || { pendiente "Configurar el firewall:  ./setup-security.sh"; return; }

    sudo rm -f /tmp/ufw_ok
    sudo sh -c 'nohup sh -c "sleep 240; [ -f /tmp/ufw_ok ] || ufw --force disable" >/dev/null 2>&1 &'
    ok "Red de seguridad activada"

    (cd "$REPO" && yes y | sudo ./setup-security.sh) >/dev/null 2>&1

    # Calibre y el panel de Pi-hole, solo desde las redes de Docker.
    # El orden importa: UFW aplica la primera regla que coincide, asi que
    # los ALLOW tienen que ir antes que los DENY.
    local red
    for red in 172.17.0.0/16 172.18.0.0/16 172.19.0.0/16 172.20.0.0/16; do
        sudo ufw allow from $red to any port 8083 proto tcp >/dev/null 2>&1
        sudo ufw allow from $red to any port 8181 proto tcp >/dev/null 2>&1
    done
    sudo ufw deny 8083/tcp >/dev/null 2>&1
    sudo ufw --force delete deny 8181 >/dev/null 2>&1
    sudo ufw deny 8181/tcp >/dev/null 2>&1
    ok "Reglas aplicadas"

    echo ""
    aviso "Proba AHORA desde otra maquina que seguis entrando por SSH."
    if preguntar "¿Podes entrar?" "s"; then
        sudo touch /tmp/ufw_ok
        ok "Confirmado, el firewall queda activo"
    else
        sudo ufw --force disable
        aviso "Firewall desactivado para no dejarte afuera"
        pendiente "Revisar el firewall:  ./setup-security.sh"
    fi
}

ejecutar() {
    titulo "Instalando"
    local mod
    for mod in "${MODULOS[@]}"; do
        [[ " ${SELECCION[*]} " == *" $mod "* ]] || continue
        echo ""
        echo "  ${B}${NOMBRE[$mod]}${N}"
        case "$mod" in
            sistema)    instalar_sistema ;;
            pihole)     instalar_pihole ;;
            calibre)    instalar_calibre ;;
            tailscale)  instalar_tailscale ;;
            seguridad)  instalar_seguridad ;;
            *)
                # levantar_modulo respeta los servicios elegidos y saltea
                # los que ya estan corriendo, asi que es seguro llamarlo
                # siempre: no reinicia nada que ya funcione.
                bajar_imagenes
                levantar_modulo "$mod"
                ;;
        esac
    done
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

esta_arriba() { $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# Recien levantado un contenedor puede tardar en atender. Esperamos.
esperar_http() {
    local svc="$1" puerto="$2" ruta="${3:-/}" i
    for i in $(seq 1 30); do
        esta_arriba "$svc" || return 1
        $DOCKER exec "$svc" curl -s -o /dev/null --max-time 4 \
            "http://localhost:$puerto$ruta" 2>/dev/null && return 0
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
        forms|basic) gris "     $svc ya tenia contrasena, no la piso"; return 0 ;;
        "")          aviso "$svc: no pude leer su configuracion"; return 1 ;;
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
    gris "     antes se entraba sin ninguna"
}

cfg_radarr() {
    local clave="$1" cuerpo
    esperar_http radarr 7878 /api/v3/system/status || { aviso "Radarr no contesta"; return 1; }

    local resp
    if arr_api radarr 7878 v3 GET /rootfolder 2>/dev/null | grep -q '/data/media/movies'; then
        gris "     carpeta raiz ya cargada"
    else
        resp=$(arr_api radarr 7878 v3 POST /rootfolder '{"path":"/data/media/movies"}' 2>/dev/null)
        if echo "$resp" | grep -q '"errorMessage"'; then
            gris "     carpeta raiz: $(echo "$resp" | python3 -c \
                'import sys,json;print(json.load(sys.stdin)[0].get("errorMessage",""))' 2>/dev/null)"
        else
            ok "Radarr: carpeta raiz ${B}/data/media/movies${N}"
        fi
    fi

    # Hardlinks: una pelicula ocupa espacio una sola vez aunque figure en
    # descargas y en la biblioteca. Sin esto el DAS se llena al doble.
    local mm
    mm=$(arr_api radarr 7878 v3 GET /config/mediamanagement 2>/dev/null)
    if [ "$(echo "$mm" | python3 -c \
        'import sys,json;print(json.load(sys.stdin).get("copyUsingHardlinks"))' 2>/dev/null)" = "True" ]; then
        gris "     hardlinks ya activados"
    elif [ -n "$mm" ]; then
        local mm2 mmid
        mm2=$(echo "$mm" | python3 -c 'import sys,json;d=json.load(sys.stdin);d["copyUsingHardlinks"]=True;print(json.dumps(d))' 2>/dev/null)
        mmid=$(echo "$mm" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",1))' 2>/dev/null)
        arr_api radarr 7878 v3 PUT "/config/mediamanagement/$mmid" "$mm2" >/dev/null 2>&1
        ok "Radarr: hardlinks activados"
    fi

    if arr_api radarr 7878 v3 GET /downloadclient 2>/dev/null | grep -qi 'qbittorrent'; then
        gris "     qBittorrent ya estaba conectado"
    elif esta_arriba qbittorrent; then
        # Con la contrasena real de qBittorrent, que puede no ser la general.
        # Radarr valida la conexion al guardar: si no puede entrar, no guarda.
        cuerpo=$(CLAVE="${CLAVE_QBIT:-$clave}" python3 -c '
import json, os
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
    {"name": "movieCategory", "value": "radarr"},
    {"name": "contentLayout", "value": 0},
    {"name": "initialState", "value": 0},
    {"name": "recentMoviePriority", "value": 0},
    {"name": "olderMoviePriority", "value": 0},
    {"name": "sequentialOrder", "value": False},
    {"name": "firstAndLast", "value": False}
  ], "tags": []}))' 2>/dev/null)
        resp=$(arr_api radarr 7878 v3 POST /downloadclient "$cuerpo" 2>/dev/null)
        if echo "$resp" | grep -q '"errorMessage"'; then
            aviso "Radarr: no pudo conectarse a qBittorrent"
            gris "     $(echo "$resp" | python3 -c \
                'import sys,json;print(json.load(sys.stdin)[0].get("errorMessage",""))' 2>/dev/null)"
            pendiente "Conectar qBittorrent en http://radarr.pi, Settings, Download Clients"
        else
            ok "Radarr: qBittorrent conectado como cliente de descargas"
        fi
    fi

    arr_autenticacion radarr 7878 v3 "$clave"
}

cfg_prowlarr() {
    local clave="$1" kr cuerpo
    esperar_http prowlarr 9696 /api/v1/system/status || { aviso "Prowlarr no contesta"; return 1; }

    kr=$(api_key_arr radarr)
    if arr_api prowlarr 9696 v1 GET /applications 2>/dev/null | grep -qi '"name": *"Radarr"'; then
        gris "     Radarr ya estaba enlazado"
    elif [ -n "$kr" ] && esta_arriba radarr; then
        cuerpo=$(KR="$kr" python3 -c '
import json, os
print(json.dumps({
  "name": "Radarr", "implementation": "Radarr",
  "implementationName": "Radarr", "configContract": "RadarrSettings",
  "syncLevel": "fullSync",
  "fields": [
    {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
    {"name": "baseUrl", "value": "http://radarr:7878"},
    {"name": "apiKey", "value": os.environ["KR"]}
  ], "tags": []}))' 2>/dev/null)
        arr_api prowlarr 9696 v1 POST /applications "$cuerpo" >/dev/null 2>&1
        ok "Prowlarr: enlazado con Radarr"
        gris "     los indexers que cargues se le sincronizan solos"
    fi

    arr_autenticacion prowlarr 9696 v1 "$clave"
}

# ── qBittorrent ───────────────────────────────────────────────────────────────

# La contrasena con la que qBittorrent quedo realmente. Puede no ser la general
# si la general tiene menos de 6 caracteres. Radarr la necesita para conectarse.
CLAVE_QBIT=""

cfg_qbittorrent() {
    local clave="$1" ck=/tmp/instalador.cookie tmp pass code entro=0 prefs resp
    esperar_http qbittorrent 8080 || { aviso "qBittorrent no contesta"; return 1; }

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
    tmp=$($DOCKER logs qbittorrent 2>&1 \
        | grep -oE "temporary password is provided for this session: [^ ]+" \
        | tail -1 | awk '{print $NF}')

    # Probamos primero la definitiva: si ya se corrio el instalador, es esa.
    for pass in "$clave" "$tmp" "adminadmin"; do
        [ -n "$pass" ] || continue
        code=$($DOCKER exec qbittorrent curl -s -o /dev/null -w '%{http_code}' -c "$ck" -X POST \
            -H "Referer: http://localhost:8080" \
            --data-urlencode "username=admin" --data-urlencode "password=$pass" \
            "http://localhost:8080/api/v2/auth/login" 2>/dev/null)
        # La 5.x contesta 204 sin cuerpo; las viejas 200 con "Ok."
        if [ "$code" = "200" ] || [ "$code" = "204" ]; then entro=1; break; fi
    done

    if [ "$entro" != "1" ]; then
        aviso "qBittorrent: no pude entrar a su API"
        gris "     suele ser un baneo temporal por intentos fallidos"
        pendiente "Poner contrasena a qBittorrent a mano en http://qbit.pi"
        return 1
    fi

    # save_path viene de fabrica en /downloads, que en este stack NO EXISTE:
    # el DAS se monta en /data. Si no se corrige, las descargas caen dentro
    # del contenedor y encima se pierde el hardlink con la biblioteca.
    prefs=$(CLAVE="$clave" python3 -c '
import json, os
print(json.dumps({
  "web_ui_username": "admin",
  "web_ui_password": os.environ["CLAVE"],
  "save_path": "/data/downloads/complete",
  "temp_path_enabled": True,
  "temp_path": "/data/downloads/incomplete",
  "create_subfolder_enabled": False,
  "start_paused_enabled": False}))' 2>/dev/null)

    resp=$($DOCKER exec qbittorrent curl -s -b "$ck" -X POST \
        -H "Referer: http://localhost:8080" \
        --data-urlencode "json=$prefs" \
        "http://localhost:8080/api/v2/app/setPreferences" 2>/dev/null)

    $DOCKER exec qbittorrent sh -c "rm -f $ck" 2>/dev/null

    if [ -n "$resp" ]; then
        aviso "qBittorrent: $resp"
        pendiente "Revisar la contrasena de qBittorrent en http://qbit.pi"
        return 1
    fi

    # Recien aca damos la contrasena por buena. Radarr la va a usar para
    # conectarse, y darsela sin que haya quedado aplicada lo haria fallar.
    CLAVE_QBIT="$clave"
    ok "qBittorrent: contrasena puesta y descargas en ${B}/data/downloads${N}"
    gris "     venia apuntando a /downloads, que en este stack no existe"
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

cfg_jellyfin() {
    local clave="$1" listo resp
    esperar_http jellyfin 8096 /System/Info/Public || { aviso "Jellyfin no contesta"; return 1; }

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

    if [ -z "$JF_TOKEN" ]; then
        aviso "Jellyfin: no pude autenticarme, salteo biblioteca y aceleracion"
        gris "     probablemente ya tenia otro usuario con otra contrasena"
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
    local clave="$1" kr salida code tmpf
    esperar_http bazarr 6767 || { aviso "Bazarr no contesta"; return 1; }
    kr=$(api_key_arr radarr)

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

    salida=$(CLAVE="$clave" RADARR_KEY="${kr:-}" ARCHIVO="$tmpf" python3 <<'PY' 2>&1
import os, hashlib, yaml

RUTA = os.environ["ARCHIVO"]
with open(RUTA) as f:
    c = yaml.safe_load(f) or {}
for s in ("general", "radarr", "auth"):
    c.setdefault(s, {})

hecho = []
key = os.environ.get("RADARR_KEY", "")
if key and c["radarr"].get("apikey") != key:
    c["general"]["use_radarr"] = True
    c["radarr"].update({"ip": "radarr", "port": 7878, "apikey": key,
                        "ssl": False, "base_url": "/"})
    hecho.append("radarr")

# Bazarr guarda la contrasena del panel como md5 en su propio config.yaml
if not c["auth"].get("type"):
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
        *radarr*|*auth*) : ;;
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
    esperar_http grafana 3000 /api/health || { aviso "Grafana no contesta"; return 1; }
    if $DOCKER exec grafana grafana cli --homepath /usr/share/grafana \
         admin reset-admin-password "$1" >/dev/null 2>&1; then
        ok "Grafana: contrasena de ${B}admin${N} puesta"
        gris "     ya no te pide cambiarla en el primer login"
    else
        aviso "Grafana: no pude cambiarle la contrasena"
        pendiente "Entrar a http://grafana.pi con admin/admin y cambiarla"
    fi
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

    pedir_clave_maestra

    local elegidos_media; elegidos_media=$(servicios_elegidos media)

    if [[ " ${SELECCION[*]} " == *" pihole "* ]]; then
        cfg_pihole "$(clave_para 'Pi-hole')"
    fi

    if [[ " ${SELECCION[*]} " == *" monitoring "* ]] && esta_arriba grafana; then
        cfg_grafana "$(clave_para 'Grafana')"
    fi

    if [[ " ${SELECCION[*]} " == *" media "* ]]; then
        # El orden importa: qBittorrent y Radarr tienen que estar configurados
        # antes de que Radarr los conecte y Prowlarr enlace a Radarr.
        esta_arriba qbittorrent && [[ " $elegidos_media " == *" qbittorrent "* ]] && \
            cfg_qbittorrent "$(clave_para 'qBittorrent')"
        esta_arriba radarr && [[ " $elegidos_media " == *" radarr "* ]] && \
            cfg_radarr "$(clave_para 'Radarr')"
        esta_arriba prowlarr && [[ " $elegidos_media " == *" prowlarr "* ]] && \
            cfg_prowlarr "$(clave_para 'Prowlarr')"
        esta_arriba bazarr && [[ " $elegidos_media " == *" bazarr "* ]] && \
            cfg_bazarr "$(clave_para 'Bazarr')"
        esta_arriba jellyfin && [[ " $elegidos_media " == *" jellyfin "* ]] && \
            cfg_jellyfin "$(clave_para 'Jellyfin')"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  GUIA DE CREACION DE CUENTAS
#
#  Crear cuentas es lo unico que un script no puede hacer por vos. Pero si
#  puede llevarte de la mano, en el orden correcto, y capturar los tokens
#  que salen de cada una en el momento en que los tenes en pantalla.
#
#  El orden importa: news-filter necesita credenciales que solo existen
#  DESPUES de crear las cuentas de FreshRSS y Wallabag.
# ══════════════════════════════════════════════════════════════════════════════

# Solo lo que NO se puede automatizar: crear una cuenta desde cero, y las
# elecciones que son tuyas (que indexers usas, en que idioma queres los
# subtitulos). Todo lo demas lo dejo hecho antes de llegar aca.
#
# modulo|servicio|url|de que se trata
CUENTAS=(
"news|freshrss|http://freshrss.pi|Crear tu cuenta y habilitar la API"
"news|wallabag|http://wallabag.pi|Cambiar la contrasena y crear el cliente de API"
"media|prowlarr|http://prowlarr.pi|Cargar los indexers que uses"
"media|bazarr|http://bazarr.pi|Elegir idiomas y proveedores de subtitulos"
"media|jellyfin|http://jellyfin.pi|Instalar los complementos"
)

# El paso a paso de cada uno, una linea por paso.
declare -A PASOS=(
[freshrss]="El asistente te pide el idioma: elegi Espanol y Continuar.
En 'Verificaciones' tiene que estar todo en verde. Continuar.
Base de datos: dejala en ${B}SQLite${N}, no toques nada. Continuar.
Crea tu usuario. Usa ${B}admin${N} y la misma contrasena que el resto.
Ya adentro: Configuracion, Perfil, y abajo de todo esta
   ${B}Contrasena de la API${N}. Ponela y guarda.
Esa contrasena de API es la que te pido despues: sin ella el filtro
   de noticias no puede leer tus feeds."

[wallabag]="Entra con ${B}wallabag${N} / ${B}wallabag${N} (las de fabrica).
Arriba a la derecha, Configuracion, pestana ${B}Cambiar contrasena${N}.
Cambiala por la tuya y guarda.
Volve a Configuracion, pestana ${B}Clientes API${N}.
Toca ${B}Crear un nuevo cliente${N}, ponele cualquier nombre y crea.
Te muestra un ${B}ID${N} y un ${B}Secreto${N}: no cierres esa pantalla,
   te los pido en cuanto termines este paso."

[prowlarr]="Entra con ${B}admin${N} y tu contrasena. Ya se la configure.
Anda a ${B}Indexers${N}, boton ${B}Add Indexer${N}, y busca los que uses.
Cada uno te pide sus datos: los publicos no piden nada, los privados
   piden la cuenta que tengas en ese tracker.
${B}No hace falta que los cargues tambien en Radarr.${N} Ya enlace los dos:
   lo que agregues aca se le sincroniza a Radarr solo.
En Settings, Apps, tiene que figurar Radarr. Si esta, quedo bien."

[bazarr]="Entra con ${B}admin${N} y tu contrasena. Ya se la configure.
${B}Settings, Languages${N}: agrega Espanol e Ingles, y despues crea un
   perfil de idiomas con los dos. Sin perfil no baja ningun subtitulo.
${B}Settings, Providers${N}: elegi de donde bajarlos. Los que andan bien sin
   pagar son OpenSubtitles.com (pide crear cuenta propia) y Subdivx.
${B}Settings, Radarr${N}: ya esta conectado, no toques nada ahi.
Si en Providers no elegis ninguno, Bazarr corre pero nunca baja nada."

[jellyfin]="Entra con ${B}admin${N} y tu contrasena. Ya cree el usuario, la
   biblioteca y la aceleracion por hardware.
${B}Panel, Complementos, Catalogo${N}, e instala los que quieras.
Los recomendados y por que, en ${B}media/JELLYFIN-PLUGINS.md${N}:
   Intro Skipper, Cinema Mode, Trickplay y Merge Versions.
Reinicia Jellyfin cuando termines de instalarlos, o no aparecen.
La biblioteca va a estar vacia hasta que montes el DAS y le pongas
   peliculas adentro."
)

# Tokens que salen de una cuenta recien creada.
# modulo|servicio|archivo|VARIABLE|descripcion|donde encontrarlo
TOKENS_DE_CUENTA=(
"news|freshrss|news/news-filter/.env|FRESHRSS_API_PASSWORD|Clave de API de FreshRSS|La que acabas de poner en Perfil, API de administracion"
"news|wallabag|news/news-filter/.env|WALLABAG_CLIENT_ID|ID de cliente de Wallabag|Aparece al crear el cliente API"
"news|wallabag|news/news-filter/.env|WALLABAG_CLIENT_SECRET|Secreto de cliente de Wallabag|Al lado del ID"
"news|wallabag|news/news-filter/.env|WALLABAG_PASSWORD|Contrasena de tu cuenta de Wallabag|La que pusiste recien"
"monitoring|pihole|monitoring/.env|PIHOLE_API_KEY|Clave de API de Pi-hole|Panel de Pi-hole, Settings, API, Generate app password"
)

guia_cuentas() {
    # Solo las cuentas de los servicios que efectivamente levantaste
    local pendientes=() linea m srv url que
    for linea in "${CUENTAS[@]}"; do
        IFS='|' read -r m srv url que <<< "$linea"
        [[ " ${SELECCION[*]} " == *" $m "* ]] || continue
        [[ " $(servicios_elegidos "$m") " == *" $srv "* ]] || continue
        $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$srv" || continue
        pendientes+=("$linea")
    done

    [ ${#pendientes[@]} -eq 0 ] && return 0

    titulo "Lo que queda para vos"

    info "Ya configure todo lo que se puede configurar solo. Lo que queda es"
    info "de dos tipos:"
    echo ""
    info "  ${B}·${N} crear una cuenta desde cero, que necesita un navegador"
    info "  ${B}·${N} elecciones que son tuyas, como que indexers usar o en que"
    info "    idioma queres los subtitulos"
    echo ""
    info "Te llevo de a uno, ${B}en el orden correcto${N}, con el paso a paso, y"
    info "despues de cada uno te pido los datos que hayan salido de ahi."
    echo ""
    aviso "Necesitas un navegador que resuelva los nombres .pi."
    gris "     Si no te abren, revisa que tu DNS apunte a $IP_FIJA."
    echo ""

    preguntar "¿Las hacemos ahora?" "s" || {
        pendiente "Crear las cuentas de: $(for l in "${pendientes[@]}"; do IFS='|' read -r _ s _ _ <<< "$l"; printf '%s ' "$s"; done)"
        return 0
    }

    local i=1 total=${#pendientes[@]}
    for linea in "${pendientes[@]}"; do
        IFS='|' read -r m srv url que <<< "$linea"
        echo ""
        echo "  ${B}[$i/$total]  ${C}${srv}${N}   ${G}$que${N}"
        echo "        ${B}$url${N}"
        echo ""

        # Las lineas que arrancan con espacios son continuacion del paso de
        # arriba, no un paso nuevo: no se numeran.
        local paso n=1
        while IFS= read -r paso; do
            [ -n "$paso" ] || continue
            if [[ "$paso" == " "* ]]; then
                echo "           ${paso#"${paso%%[![:space:]]*}"}"
            else
                printf "        ${B}%d.${N} %s\n" "$n" "$paso"
                n=$((n+1))
            fi
        done <<< "${PASOS[$srv]:-$que}"

        echo ""
        read -r -p "        ${B}Enter cuando termines${N} (o 's' para saltear): " r </dev/tty
        if [[ "$r" =~ ^[Ss]$ ]]; then
            aviso "Salteado"
            pendiente "Crear la cuenta de $srv en $url"
            i=$((i+1)); continue
        fi
        ok "Listo"

        # Si de esta cuenta salen tokens, los pido ahora que los tenes a mano
        local t tm ts tarch tvar tdesc tdonde
        for t in "${TOKENS_DE_CUENTA[@]}"; do
            IFS='|' read -r tm ts tarch tvar tdesc tdonde <<< "$t"
            [ "$ts" = "$srv" ] || continue
            completa "$tarch" "$tvar" && continue
            echo ""
            echo "        ${C}$tdesc${N}"
            gris "        $tdonde"
            local valor
            read -r -p "        ${B}valor${N} (Enter para saltear): " valor </dev/tty
            if [ -n "$valor" ]; then
                escribir_var "$tarch" "$tvar" "$valor"
                ok "Guardado en $tarch"
            else
                aviso "Salteado"
                INCOMPLETOS+=("$tm|$tarch|$tvar|$tdesc|$tdonde")
            fi
        done

        i=$((i+1))
    done

    # Si se completaron las credenciales del filtro de noticias, hay que
    # recrear el contenedor para que las tome.
    if [[ " ${SELECCION[*]} " == *" news "* ]] \
       && completa news/news-filter/.env FRESHRSS_API_PASSWORD \
       && completa news/news-filter/.env WALLABAG_CLIENT_ID; then
        echo ""
        info "Ya estan las credenciales del filtro de noticias. Lo recreo para que las tome."
        $DOCKER compose up -d --force-recreate news-filter >/dev/null 2>&1
        ok "news-filter recreado"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  RESUMEN
# ══════════════════════════════════════════════════════════════════════════════

resumen() {
    detectar
    titulo "Como quedo"

    local mod
    for mod in "${SELECCION[@]}"; do
        printf "  %s  %-56s %s\n" "$(icono "${ESTADO[$mod]}")" "${NOMBRE[$mod]}" "$(etiqueta "${ESTADO[$mod]}")"
    done

    if [ ${#INCOMPLETOS[@]} -gt 0 ]; then
        echo ""
        echo "  ${A}${B}Datos que salteaste${N}"
        echo ""
        info "El servicio funciona, pero esa parte no va a andar hasta que los cargues."
        echo ""
        local linea m arch v desc ayuda
        for linea in "${INCOMPLETOS[@]}"; do
            IFS='|' read -r m arch v desc ayuda <<< "$linea"
            echo "  ${B}·${N} ${C}$desc${N}"
            if [ "$v" = "(archivo)" ]; then
                gris "      es el archivo:  $arch"
            else
                gris "      va en:  $arch  ->  $v="
            fi
            [ -n "$ayuda" ] && gris "      donde:  $ayuda"
        done
        echo ""
        info "Para cargarlos, volve a correr:  ${B}./instalador.sh${N}"
        info "Te va a pedir solo los que falten."
    fi

    if [ ${#PENDIENTES[@]} -gt 0 ]; then
        echo ""
        echo "  ${A}${B}Tareas pendientes${N}"
        echo ""
        local p
        for p in "${PENDIENTES[@]}"; do echo "  ${B}·${N} $p"; done
    fi

    if [ -n "$CLAVE_MAESTRA" ]; then
        echo ""
        echo "  ${B}Con que entras a cada cosa${N}"
        echo ""
        info "Usuario ${B}admin${N} en todos, con la contrasena que elegiste."
        echo ""
        local c
        [[ " ${SELECCION[*]} " == *" core "* ]]       && gris "     http://homepage.pi     panel de inicio"
        [[ " ${SELECCION[*]} " == *" monitoring "* ]] && gris "     http://grafana.pi      tableros"
        [[ " ${SELECCION[*]} " == *" monitoring "* ]] && gris "     http://prometheus.pi   metricas crudas"
        [[ " ${SELECCION[*]} " == *" pihole "* ]]     && gris "     http://pihole.pi       DNS y bloqueo"
        [[ " ${SELECCION[*]} " == *" media "* ]]      && {
            gris "     http://jellyfin.pi     peliculas"
            gris "     http://qbit.pi         descargas"
            gris "     http://radarr.pi       automatizacion"
            gris "     http://prowlarr.pi     indexers"
            gris "     http://bazarr.pi       subtitulos"
        }
        [[ " ${SELECCION[*]} " == *" calibre "* ]]    && gris "     http://calibre.pi      libros"
        [[ " ${SELECCION[*]} " == *" news "* ]]       && {
            echo ""
            info "Estos dos los creaste vos, con lo que hayas puesto:"
            gris "     http://freshrss.pi     lector de RSS"
            gris "     http://wallabag.pi     articulos guardados"
        }
    fi

    echo ""
    echo "  ${B}Documentacion${N}"
    gris "     docs/INDICE.md       ·  mapa de todo"
    gris "     docs/INSTALADOR.md   ·  como funciona este script"
    gris "     docs/OPERACION.md    ·  el dia a dia"
    echo ""
    echo "  ${A}Lo mas importante:${N} apaga siempre con ${B}sudo poweroff${N}."
    gris "     Cortar la corriente a lo bruto es lo que corrompe la tarjeta."
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════

[ -f "$REPO/docker-compose.yml" ] || { falla "Corré esto parado en la raiz del repo."; exit 1; }

# Todo el instalador pregunta cosas. Sin terminal, cada pregunta fallaria en
# silencio y algunas quedarian girando en vano.
if ! : < /dev/tty 2>/dev/null; then
    falla "Este instalador es interactivo y no encuentra una terminal."
    info "Corrélo parado en la Pi, o por SSH abriendo sesion:"
    echo ""
    echo "    ssh jlussich@$IP_FIJA"
    echo "    cd ~/pi-services && ./instalador.sh"
    echo ""
    exit 1
fi

if ! sudo -n true 2>/dev/null; then
    falla "sudo pide contrasena y el instalador lo necesita seguido."
    info "Arreglalo asi y volve a correrlo:"
    echo ""
    echo "    echo \"\$USER ALL=(ALL) NOPASSWD: ALL\" | sudo tee /etc/sudoers.d/010-\$USER > /dev/null"
    echo "    sudo chmod 440 /etc/sudoers.d/010-\$USER"
    echo ""
    exit 1
fi

portada
info "Revisando el estado del equipo..."
detectar
diagnostico
faltantes_detallado
menu
elegir_servicios
recolectar
ejecutar
configurar_servicios
guia_cuentas
resumen
