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
)

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
        gris "         va en:  $arch  ->  $v="
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

    echo ""
    info "Te voy a pedir ${B}${#faltantes[@]}${N} datos, de a uno."
    info "Si alguno no lo tenes a mano, apreta Enter y seguimos: el modulo se"
    info "instala igual y al final te digo exactamente que quedo sin completar."
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
                read -r -s -p "        ${B}valor${N} (Enter para saltear): " valor </dev/tty; echo ""
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
#  GUIA DE CREACION DE CUENTAS
#
#  Crear cuentas es lo unico que un script no puede hacer por vos. Pero si
#  puede llevarte de la mano, en el orden correcto, y capturar los tokens
#  que salen de cada una en el momento en que los tenes en pantalla.
#
#  El orden importa: news-filter necesita credenciales que solo existen
#  DESPUES de crear las cuentas de FreshRSS y Wallabag.
# ══════════════════════════════════════════════════════════════════════════════

# modulo|servicio|url|que hacer
CUENTAS=(
"monitoring|grafana|http://grafana.pi|Entra con usuario ${B}admin${N} y contrasena ${B}admin${N}. Te va a obligar a cambiarla en el primer login."
"news|freshrss|http://freshrss.pi|Segui el asistente y crea tu usuario. Al terminar, entra a Configuracion, Perfil, y activa la ${B}API de administracion${N} poniendo una contrasena de API."
"news|wallabag|http://wallabag.pi|Entra con ${B}wallabag${N} / ${B}wallabag${N} y cambia la contrasena. Despues anda a Configuracion, Clientes API, y crea un cliente nuevo."
"media|jellyfin|http://jellyfin.pi|Segui el asistente: idioma, tu usuario, y despues agrega una biblioteca de Peliculas apuntando a ${B}/media/movies${N}."
"media|qbittorrent|http://qbit.pi|Tu contrasena temporal esta abajo. Entra, cambiala, y configura las descargas en ${B}/data/downloads${N}."
"media|prowlarr|http://prowlarr.pi|Crea tu usuario y agrega tus indexers. Despues, en Settings, Apps, agrega Radarr con la URL ${B}http://radarr:7878${N}."
"media|radarr|http://radarr.pi|Crea tu usuario. Carpeta raiz ${B}/data/media/movies${N}, y activa ${B}Use Hardlinks instead of Copy${N}."
"media|bazarr|http://bazarr.pi|Crea tu usuario, conecta Radarr en ${B}http://radarr:7878${N} y elegi proveedores de subtitulos."
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

    titulo "Crear las cuentas"

    info "Esto es lo unico que un script no puede hacer por vos: cada servicio"
    info "necesita que crees tu usuario la primera vez."
    echo ""
    info "Te llevo de a uno, ${B}en el orden correcto${N}, y despues de cada uno te"
    info "pido los datos que hayan salido de ahi."
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
        echo "  ${B}[$i/$total]  ${C}${srv}${N}"
        echo "        ${B}$url${N}"
        echo ""
        echo "        $que"

        # qBittorrent genera una contrasena temporal en su log
        if [ "$srv" = "qbittorrent" ]; then
            local tmp
            tmp=$($DOCKER logs qbittorrent 2>&1 | grep -oE "temporary password is provided for this session: [^ ]+" | tail -1 | awk '{print $NF}')
            [ -n "$tmp" ] && echo "        ${A}contrasena temporal: ${B}$tmp${N}"
        fi

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
            gris "      va en:  $arch  ->  $v="
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

    echo ""
    echo "  ${B}Cuentas que tenes que crear vos${N}"
    echo ""
    info "La primera vez que entres a cada uno te va a pedir crear usuario."
    info "Eso no lo puede hacer un script."
    echo ""
    local cuentas=""
    [[ " ${SELECCION[*]} " == *" monitoring "* ]] && cuentas="$cuentas grafana.pi"
    [[ " ${SELECCION[*]} " == *" news "* ]] && cuentas="$cuentas freshrss.pi wallabag.pi"
    [[ " ${SELECCION[*]} " == *" media "* ]] && cuentas="$cuentas jellyfin.pi radarr.pi prowlarr.pi bazarr.pi qbit.pi"
    for c in $cuentas; do gris "     http://$c"; done
    [[ " ${SELECCION[*]} " == *" media "* ]] && {
        echo ""
        info "La contrasena temporal de qBittorrent:"
        gris "     docker logs qbittorrent 2>&1 | grep -i password"
    }

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
guia_cuentas
resumen
