#!/bin/bash
# ==============================================================================
# bootstrap.sh — Instalacion guiada del Pi desde cero
#
# Pensado para que alguien sin contexto pueda levantar todo el stack siguiendo
# los pasos. Cada paso:
#
#   - detecta si ya esta hecho y ofrece saltearlo
#   - explica que va a hacer ANTES de hacerlo
#   - pide los datos que necesita, y deja saltear los que no tengas a mano
#   - se detiene si algo falla, en vez de seguir de largo
#
# Es idempotente: podes cortarlo y volver a correrlo cuando quieras.
#
#   Uso:  ./bootstrap.sh
#         ./bootstrap.sh --desde 7     empieza en el paso 7
#         ./bootstrap.sh --listar      muestra los pasos y sale
# ==============================================================================

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESTADO="$HOME/.pi-services-bootstrap"
IP_FIJA="192.168.68.66"
MASCARA="22"
GATEWAY="192.168.68.1"

V=$'\e[0;32m'; R=$'\e[0;31m'; A=$'\e[1;33m'; C=$'\e[0;36m'; N=$'\e[0m'; B=$'\e[1m'

TOTAL=13
ACTUAL=0
SALTEADOS=()
PENDIENTES=()

# ── helpers ───────────────────────────────────────────────────────────────────

paso() {
    ACTUAL=$((ACTUAL + 1))
    echo ""
    echo "${B}${C}━━━ Paso $ACTUAL de $TOTAL: $1 ━━━${N}"
}

ok()      { echo "  ${V}✓${N} $1"; }
info()    { echo "    $1"; }
aviso()   { echo "  ${A}!${N} $1"; }
error()   { echo "  ${R}✗${N} $1"; }
pendiente() { PENDIENTES+=("$1"); }

# Pregunta si/no. Segundo argumento: "s" o "n" para el valor por defecto.
preguntar() {
    local pregunta="$1" defecto="${2:-s}" resp sufijo
    [ "$defecto" = "s" ] && sufijo="[S/n]" || sufijo="[s/N]"
    read -r -p "  ${B}$pregunta${N} $sufijo " resp </dev/tty
    resp="${resp:-$defecto}"
    [[ "$resp" =~ ^[SsYy] ]]
}

# Pide un valor. Enter vacio = saltear.
pedir_valor() {
    local etiqueta="$1" ayuda="${2:-}" valor
    [ -n "$ayuda" ] && echo "    ${A}$ayuda${N}"
    read -r -p "  ${B}$etiqueta${N} (Enter para saltear): " valor </dev/tty
    echo "$valor"
}

marcar_hecho()  { echo "$1" >> "$ESTADO"; }
ya_hecho()      { [ -f "$ESTADO" ] && grep -qx "$1" "$ESTADO"; }

# Ofrece saltear un paso que ya parece estar hecho.
saltear_si_hecho() {
    local clave="$1" motivo="$2"
    if ya_hecho "$clave"; then
        ok "Ya estaba hecho ($motivo)"
        if ! preguntar "¿Hacerlo de nuevo igual?" "n"; then
            SALTEADOS+=("$clave")
            return 0
        fi
    fi
    return 1
}

# ── argumentos ────────────────────────────────────────────────────────────────

DESDE=1
while [ $# -gt 0 ]; do
    case "$1" in
        --desde)  DESDE="$2"; shift 2 ;;
        --listar)
            cat <<'LISTA'
  1  Verificaciones previas
  2  Base del sistema (zona horaria, chequeo periodico del disco)
  3  IP estatica
  4  Docker
  5  Pi-hole (DNS, listas de bloqueo, registros locales)
  6  El repositorio
  7  Variables de entorno (.env)
  8  La red de Docker
  9  Levantar los servicios
 10  Calibre (nativo, no Docker)
 11  log2ram (menos escrituras a la tarjeta)
 12  Tailscale (acceso remoto)
 13  UFW y fail2ban
LISTA
            exit 0 ;;
        *) echo "Opcion desconocida: $1"; exit 1 ;;
    esac
done

saltar() { [ "$ACTUAL" -lt "$DESDE" ]; }

# ── inicio ────────────────────────────────────────────────────────────────────

clear
cat <<'PORTADA'
  ╔══════════════════════════════════════════════════════════╗
  ║           Pi-Services — instalacion guiada               ║
  ╚══════════════════════════════════════════════════════════╝
PORTADA
echo ""
echo "  Te va a ir guiando paso a paso. En cada uno te explica que hace"
echo "  antes de hacerlo, y podes saltear el que quieras."
echo ""
echo "  Lo que no tengas a mano ahora (contrasenas, tokens) se puede"
echo "  saltear y completar despues. Al final te dice que quedo pendiente."
echo ""
echo "  Podes cortar con Ctrl+C y retomar corriendo el script de nuevo."
echo ""
preguntar "¿Arrancamos?" "s" || exit 0

# ══ 1. Verificaciones previas ═════════════════════════════════════════════════
paso "Verificaciones previas"
if ! saltar; then
    info "Antes de tocar nada, confirmo que el equipo sirve para esto."
    echo ""

    ARQ=$(uname -m)
    if [ "$ARQ" = "aarch64" ]; then ok "Arquitectura: $ARQ (64 bits)"
    else error "Arquitectura $ARQ. Hace falta aarch64 (64 bits). Regraba con Raspberry Pi OS de 64 bits."; exit 1; fi

    ok "Sistema: $(grep PRETTY /etc/os-release | cut -d'"' -f2)"
    ok "RAM: $(free -h | awk '/Mem:/ {print $2}')"
    ok "Disco: $(df -h / | tail -1 | awk '{print $4" libres de "$2}')"

    if sudo -n true 2>/dev/null; then
        ok "sudo sin contrasena"
    else
        error "sudo pide contrasena, y el script lo necesita seguido."
        info "Arreglalo con este comando y volve a correr el script:"
        echo ""
        echo "    echo \"\$USER ALL=(ALL) NOPASSWD: ALL\" | sudo tee /etc/sudoers.d/010-\$USER > /dev/null"
        echo "    sudo chmod 440 /etc/sudoers.d/010-\$USER"
        echo ""
        exit 1
    fi

    if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then ok "Hay internet"
    else error "Sin internet. Revisa el cable o el wifi."; exit 1; fi

    ESCRITORIO=$(dpkg -l 2>/dev/null | grep -cE "^ii  (lightdm|xserver-xorg-core|chromium)")
    if [ "$ESCRITORIO" -gt 0 ]; then
        aviso "Hay entorno de escritorio instalado ($ESCRITORIO paquetes)."
        info "En un servidor sin monitor son gigas de superficie que se puede"
        info "corromper, y varios de sus servicios fallan sin que los uses."
        if preguntar "¿Sacarlo?" "s"; then
            sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y \
                lightdm xserver-xorg-core chromium cups vlc >/dev/null 2>&1
            sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y >/dev/null 2>&1
            ok "Escritorio removido"
        fi
    else
        ok "Sin entorno de escritorio (correcto para un servidor)"
    fi
    marcar_hecho "1-verificaciones"
fi

# ══ 2. Base del sistema ═══════════════════════════════════════════════════════
paso "Base del sistema"
if ! saltar && ! saltear_si_hecho "2-base" "zona horaria y chequeo de disco"; then
    info "Zona horaria, y el chequeo periodico del disco."
    echo ""
    aviso "Este ultimo importa: viene DESACTIVADO de fabrica, y por eso un"
    info "sistema de archivos danado puede degradarse durante meses sin que"
    info "nadie se entere. Es lo que paso en la instalacion anterior."
    echo ""

    TZ_ACTUAL=$(timedatectl show -p Timezone --value)
    NUEVA_TZ=$(pedir_valor "Zona horaria [$TZ_ACTUAL]" "Ejemplo: America/Montevideo")
    if [ -n "$NUEVA_TZ" ]; then
        sudo timedatectl set-timezone "$NUEVA_TZ" && ok "Zona horaria: $NUEVA_TZ"
    else
        ok "Se deja como esta: $TZ_ACTUAL"
    fi

    RAIZ=$(findmnt -no SOURCE /)
    sudo tune2fs -c 30 "$RAIZ" >/dev/null 2>&1 && ok "Chequeo del disco cada 30 arranques"

    if preguntar "¿Actualizar los paquetes del sistema? (tarda un rato)" "s"; then
        info "Actualizando, puede demorar varios minutos..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >/dev/null 2>&1
        ok "Paquetes actualizados"
    fi
    marcar_hecho "2-base"
fi

# ══ 3. IP estatica ════════════════════════════════════════════════════════════
paso "IP estatica"
if ! saltar; then
    IP_ACTUAL=$(hostname -I | awk '{print $1}')
    info "IP actual: $IP_ACTUAL"
    echo ""
    aviso "La IP tiene que ser fija: esta escrita en el Caddyfile, en los"
    info "registros DNS de Pi-hole y en las reglas del firewall. Si cambia,"
    info "se rompen los tres."
    echo ""

    if [ "$IP_ACTUAL" = "$IP_FIJA" ] && nmcli -g ipv4.method con show "$(nmcli -t -f NAME con show --active | head -1)" 2>/dev/null | grep -q manual; then
        ok "Ya es estatica en $IP_FIJA"
    else
        NUEVA_IP=$(pedir_valor "IP fija [$IP_FIJA]" "Enter para usar la de siempre")
        NUEVA_IP="${NUEVA_IP:-$IP_FIJA}"
        CONEXION=$(nmcli -t -f NAME con show --active | head -1)

        aviso "Al aplicar esto se corta tu sesion SSH si estas conectado."
        info "Volves a entrar con:  ssh $USER@$NUEVA_IP"
        echo ""
        if preguntar "¿Aplicar $NUEVA_IP/$MASCARA ahora?" "s"; then
            sudo nmcli con mod "$CONEXION" \
                ipv4.addresses "$NUEVA_IP/$MASCARA" \
                ipv4.gateway "$GATEWAY" \
                ipv4.dns "9.9.9.9" \
                ipv4.method manual
            ok "Configurada. Aplicando en 3 segundos..."
            sleep 3
            sudo sh -c "nohup nmcli con up '$CONEXION' >/dev/null 2>&1 &"
            echo ""
            aviso "Si se corto, volve a entrar y corre:  ./bootstrap.sh --desde 4"
            exit 0
        fi
    fi
    marcar_hecho "3-ip"
fi

# ══ 4. Docker ═════════════════════════════════════════════════════════════════
paso "Docker"
if ! saltar; then
    if command -v docker >/dev/null 2>&1; then
        ok "Ya instalado: $(docker --version)"
    else
        info "Docker es lo que corre los 20 servicios."
        if preguntar "¿Instalarlo?" "s"; then
            curl -fsSL https://get.docker.com | sudo sh >/dev/null 2>&1
            sudo usermod -aG docker "$USER"
            sudo systemctl enable --now docker >/dev/null 2>&1
            ok "Docker instalado: $(docker --version 2>/dev/null)"
            aviso "Para usar docker sin sudo, cerra sesion y volve a entrar."
        fi
    fi
    marcar_hecho "4-docker"
fi

# ══ 5. Pi-hole ════════════════════════════════════════════════════════════════
paso "Pi-hole"
if ! saltar; then
    if command -v pihole >/dev/null 2>&1; then
        ok "Ya instalado"
    else
        info "Pi-hole hace de servidor DNS y bloquea publicidad."
        info "Va nativo, no en Docker, para que responda aunque Docker se caiga."
        echo ""
        if preguntar "¿Instalarlo?" "s"; then
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
    fi

    if command -v pihole-FTL >/dev/null 2>&1; then
        PUERTO=$(sudo pihole-FTL --config webserver.port 2>/dev/null)
        if echo "$PUERTO" | grep -q "^80o"; then
            aviso "Pi-hole esta ocupando el puerto 80, que necesita Caddy."
            if preguntar "¿Moverlo al 8181?" "s"; then
                sudo pihole-FTL --config webserver.port "8181o,[::]:8181o" >/dev/null
                sudo systemctl restart pihole-FTL
                ok "Movido al 8181"
            fi
        else
            ok "Puerto web: $PUERTO (el 80 queda libre para Caddy)"
        fi

        if preguntar "¿Cargar los registros DNS de los servicios (*.pi)?" "s"; then
            H="["
            for s in homepage grafana wallabag freshrss news finance prometheus pihole fitbit calibre jellyfin radarr prowlarr bazarr qbit; do
                H="$H\"$IP_FIJA $s.pi\","
            done
            H="${H%,}]"
            sudo pihole-FTL --config dns.hosts "$H" >/dev/null 2>&1
            sudo systemctl restart pihole-FTL
            ok "15 registros cargados"
        fi

        echo ""
        info "Listas de bloqueo. HaGeZi Ultimate es la mas estricta que hay:"
        info "unos 365.000 dominios, incluye publicidad, rastreo y telemetria."
        if preguntar "¿Agregar HaGeZi Ultimate?" "s"; then
            U="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/ultimate.txt"
            printf "INSERT OR IGNORE INTO adlist (address, enabled, comment) VALUES ('%s', 1, 'HaGeZi Ultimate');\n" "$U" \
                | sudo pihole-FTL sqlite3 /etc/pihole/gravity.db 2>/dev/null
            info "Descargando las listas, tarda unos minutos..."
            sudo pihole -g >/dev/null 2>&1
            ok "$(sudo pihole-FTL sqlite3 /etc/pihole/gravity.db 'SELECT COUNT(*) FROM gravity;' 2>/dev/null) dominios bloqueados"
        fi

        echo ""
        aviso "Pi-hole queda SIN contrasena: su panel es accesible desde tu LAN."
        info "Poner una es interactivo, asi que lo hacemos aparte."
        if preguntar "¿Ponerla ahora?" "s"; then
            sudo pihole setpassword </dev/tty || pendiente "Poner contrasena a Pi-hole: sudo pihole setpassword"
        else
            pendiente "Poner contrasena a Pi-hole: sudo pihole setpassword"
        fi
    fi
    marcar_hecho "5-pihole"
fi

# ══ 6. El repositorio ═════════════════════════════════════════════════════════
paso "El repositorio"
if ! saltar; then
    if [ -d "$REPO/.git" ]; then
        ok "Ya estas dentro del repo: $REPO"
        info "Commits: $(git -C "$REPO" log --oneline 2>/dev/null | wc -l)"
    else
        aviso "No parece un repo git. Cloná primero:"
        info "git clone https://github.com/Jerolussich/Pi-Services.git ~/pi-services"
        exit 1
    fi
    marcar_hecho "6-repo"
fi

# ══ 7. Variables de entorno ═══════════════════════════════════════════════════
paso "Variables de entorno (.env)"
if ! saltar; then
    info "Cada servicio necesita su archivo .env. Los que llevan rutas o"
    info "datos del equipo los completo yo; los que llevan contrasenas te"
    info "los voy a pedir, y podes saltear los que no tengas a mano."
    echo ""

    cd "$REPO"

    # --- los automaticos ---
    echo "PI_IP=$IP_FIJA" > homepage/.env
    echo "PI_IP=$IP_FIJA" > news/wallabag/.env
    cat > monitoring/.env <<EOF
PIHOLE_API_KEY=
FITBIT_EXPORTS_PATH=$REPO/fitbit-exporter/exports
FINANCE_DATA_PATH=$REPO/finance/finance-tracker/data
EOF
    cat > media/.env <<EOF
PUID=$(id -u)
PGID=$(id -g)
TZ=$(timedatectl show -p Timezone --value)
DAS_ROOT=/mnt/das
JELLYFIN_PublishedServerUrl=http://jellyfin.pi
QBIT_TORRENT_PORT=6881
EOF
    touch news/freshrss/.env
    [ -f news/news-filter/.env ] || cp news/news-filter/.env.example news/news-filter/.env
    mkdir -p fitbit-exporter/exports finance/finance-tracker/data news/news-filter/data
    ok "Completados los automaticos (rutas, IP, usuario, zona horaria)"

    # --- Caddy: hash bcrypt ---
    echo ""
    info "${B}Caddy${N} protege homepage, prometheus y calibre, que no tienen login propio."
    if [ -s caddy/.env ] && grep -q '\$\$2' caddy/.env 2>/dev/null; then
        ok "Ya tiene contrasena configurada"
    elif preguntar "¿Configurar su contrasena ahora?" "s"; then
        read -r -s -p "  ${B}Contrasena para el usuario admin:${N} " CLAVE </dev/tty; echo ""
        if [ -n "$CLAVE" ]; then
            info "Generando el hash (bcrypt es lento a proposito, aguanta)..."
            HASH=$(sudo docker run --rm caddy:2-alpine caddy hash-password --plaintext "$CLAVE" 2>/dev/null)
            if [ -n "$HASH" ]; then
                # Cada $ va escapado como $$ o Compose lo toma por variable
                printf 'CADDY_USER=admin\nCADDY_PASSWORD_HASH=%s\n' "${HASH//\$/\$\$}" > caddy/.env
                ok "Contrasena de Caddy configurada"
            else
                error "No se pudo generar el hash. ¿Docker esta andando?"
                pendiente "Configurar caddy/.env"
            fi
            unset CLAVE HASH
        fi
    else
        pendiente "Configurar la contrasena de Caddy en caddy/.env"
    fi

    # --- los tres paneles con login propio ---
    echo ""
    info "${B}Fitbit, News Filter y Finance${N} tienen su propio login."
    if preguntar "¿Configurar sus contrasenas? (podes usar la misma para los tres)" "s"; then
        read -r -s -p "  ${B}Contrasena para los tres paneles:${N} " CLAVE2 </dev/tty; echo ""
        if [ -n "$CLAVE2" ]; then
            for destino in fitbit-exporter/ui/.env news/news-filter/ui/.env finance/finance-tracker/.env; do
                mkdir -p "$(dirname "$destino")"
                {
                    echo "UI_USERNAME=admin"
                    echo "UI_PASSWORD=$CLAVE2"
                    echo "SECRET_KEY=$(python3 -c 'import secrets;print(secrets.token_hex(32))')"
                } > "$destino"
            done
            ok "Configurados los tres, con claves de sesion aleatorias"
            unset CLAVE2
        fi
    else
        pendiente "Configurar UI_PASSWORD en fitbit-exporter/ui/.env, news/news-filter/ui/.env y finance/finance-tracker/.env"
    fi

    echo ""
    aviso "news-filter necesita ademas credenciales de FreshRSS y Wallabag,"
    info "que solo existen DESPUES de crear esas dos cuentas. Queda pendiente."
    pendiente "Completar news/news-filter/.env con las credenciales de FreshRSS y Wallabag"

    marcar_hecho "7-env"
fi

# ══ 8. La red de Docker ═══════════════════════════════════════════════════════
paso "La red de Docker"
if ! saltar; then
    aviso "Este paso es facil de olvidar y cuesta caro."
    info "Tres servicios declaran la red 'pi-services' como externa, porque"
    info "estan pensados para poder correr sueltos. Si no existe de antes, el"
    info "'up' construye todas las imagenes durante una hora y recien al final"
    info "falla, sin levantar nada."
    echo ""
    if sudo docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "pi-services"; then
        ok "La red ya existe"
    else
        sudo docker network create pi-services >/dev/null 2>&1 && ok "Red 'pi-services' creada"
    fi
    marcar_hecho "8-red"
fi

# ══ 9. Levantar los servicios ═════════════════════════════════════════════════
paso "Levantar los servicios"
if ! saltar; then
    info "Son 20 contenedores. La primera vez tarda bastante: baja las"
    info "imagenes y construye seis propias."
    echo ""
    aviso "Consejo aprendido a los golpes: en una tarjeta SD, bajar todas las"
    info "imagenes en paralelo la satura y el proceso se cuelga. Este script"
    info "las baja de a una, que es mas lento pero no falla."
    echo ""
    if preguntar "¿Levantar todo ahora?" "s"; then
        cd "$REPO"
        info "Bajando las imagenes de a una..."
        for img in $(sudo docker compose config 2>/dev/null | grep -oE '^\s+image: .*' | awk '{print $2}' | sort -u); do
            if sudo docker image inspect "$img" >/dev/null 2>&1; then
                info "  ya estaba: $img"
            else
                info "  bajando: $img"
                sudo docker pull "$img" >/dev/null 2>&1 && ok "  $img" || aviso "  fallo: $img"
            fi
        done
        info "Construyendo y levantando..."
        sudo docker compose up -d
        echo ""
        ok "$(sudo docker ps -q | wc -l) contenedores arriba"
    fi
    marcar_hecho "9-servicios"
fi

# ══ 10. Calibre ═══════════════════════════════════════════════════════════════
paso "Calibre"
if ! saltar; then
    info "Calibre va nativo, no en Docker."
    if systemctl --user is-active calibre-server >/dev/null 2>&1; then
        ok "Ya esta corriendo"
    elif preguntar "¿Instalarlo?" "s"; then
        (cd "$REPO/calibre" && ./install.sh)
        # El instalador no puede terminar por SSH: le falta la sesion de
        # usuario para hablar con systemd. Se completa a mano.
        sudo loginctl enable-linger "$USER" 2>/dev/null
        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
        systemctl --user daemon-reload 2>/dev/null
        systemctl --user enable --now calibre-server 2>/dev/null
        systemctl --user enable --now calibre-ingest.timer 2>/dev/null
        if systemctl --user is-active calibre-server >/dev/null 2>&1; then
            ok "Calibre andando en el puerto 8083"
        else
            aviso "No arranco. Revisalo con: systemctl --user status calibre-server"
            pendiente "Revisar por que no arranca calibre-server"
        fi
    fi
    marcar_hecho "10-calibre"
fi

# ══ 11. log2ram ═══════════════════════════════════════════════════════════════
paso "log2ram"
if ! saltar; then
    info "Mantiene los logs en memoria y los baja a disco una vez por dia."
    info "Menos escrituras a la tarjeta significa menos momentos en los que"
    info "un corte de luz te agarre a mitad de una, que es como se corrompen."
    echo ""
    if systemctl is-enabled log2ram >/dev/null 2>&1; then
        ok "Ya instalado"
    elif preguntar "¿Instalarlo? (agrega el repositorio de azlux)" "s"; then
        curl -fsSL https://azlux.fr/repo.gpg | sudo tee /usr/share/keyrings/azlux-archive-keyring.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] http://packages.azlux.fr/debian/ stable main" \
            | sudo tee /etc/apt/sources.list.d/azlux.list >/dev/null
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y log2ram >/dev/null 2>&1
        sudo sed -i 's|^SIZE=.*|SIZE=512M|' /etc/log2ram.conf
        ok "Instalado (512 MB). Se activa en el proximo reinicio."
        pendiente "Reiniciar para que log2ram tome efecto"
    fi
    marcar_hecho "11-log2ram"
fi

# ══ 12. Tailscale ═════════════════════════════════════════════════════════════
paso "Tailscale"
if ! saltar; then
    info "Acceso remoto sin abrir puertos en el router."
    echo ""
    info "Tres cosas que te da:"
    info "  · llegar a tus servicios desde afuera de casa"
    info "  · que el celular use Pi-hole estando en la calle"
    info "  · entrar por SSH aunque Docker se rompa, porque corre en el sistema"
    echo ""
    if command -v tailscale >/dev/null 2>&1 && sudo tailscale status >/dev/null 2>&1; then
        ok "Ya conectado: $(sudo tailscale ip -4 2>/dev/null | head -1)"
    elif preguntar "¿Instalarlo?" "s"; then
        command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sudo sh
        echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-tailscale.conf >/dev/null
        echo "net.ipv6.conf.all.forwarding = 1" | sudo tee -a /etc/sysctl.d/99-tailscale.conf >/dev/null
        sudo sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null 2>&1
        echo ""
        aviso "Va a mostrarte una URL. Abrila en el navegador y autoriza el equipo."
        echo ""
        sudo tailscale up --advertise-routes=192.168.68.0/22 --accept-dns=false </dev/tty
        echo ""
        aviso "Falta hacer 3 cosas a mano en login.tailscale.com:"
        info "  1. Aprobar la ruta 192.168.68.0/22 en Machines, Edit route settings"
        info "  2. Agregar $IP_FIJA como nameserver global, en DNS"
        info "  3. Activar 'Override DNS servers'"
        info "Sin esos tres pasos el celular no usa Pi-hole fuera de casa."
        pendiente "Aprobar la ruta y configurar el DNS en login.tailscale.com"
    fi
    marcar_hecho "12-tailscale"
fi

# ══ 13. UFW y fail2ban ════════════════════════════════════════════════════════
paso "UFW y fail2ban"
if ! saltar; then
    aviso "Este paso va al final a proposito: si algo sale mal, te podes"
    info "quedar sin acceso SSH."
    echo ""
    info "Para eso el script activa una red de seguridad: si en 4 minutos no"
    info "confirmas que seguis entrando, el firewall se desactiva solo."
    echo ""
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        ok "UFW ya esta activo"
    elif preguntar "¿Configurar el firewall?" "s"; then
        sudo rm -f /tmp/ufw_ok
        sudo sh -c 'nohup sh -c "sleep 240; [ -f /tmp/ufw_ok ] || ufw --force disable" >/dev/null 2>&1 &'
        ok "Red de seguridad activada (4 minutos)"

        (cd "$REPO" && yes y | sudo ./setup-security.sh) 2>&1 | tail -5

        # Calibre y el panel de Pi-hole: solo desde las redes de Docker.
        # El orden importa: los ALLOW tienen que ir ANTES que los DENY.
        for red in 172.17.0.0/16 172.18.0.0/16 172.19.0.0/16 172.20.0.0/16; do
            sudo ufw allow from $red to any port 8083 proto tcp >/dev/null 2>&1
            sudo ufw allow from $red to any port 8181 proto tcp >/dev/null 2>&1
        done
        sudo ufw deny 8083/tcp >/dev/null 2>&1
        sudo ufw --force delete deny 8181 >/dev/null 2>&1
        sudo ufw deny 8181/tcp >/dev/null 2>&1

        echo ""
        aviso "Probá AHORA desde otra maquina que seguis entrando por SSH."
        if preguntar "¿Podes entrar?" "s"; then
            sudo touch /tmp/ufw_ok
            ok "Confirmado, el firewall queda activo"
        else
            sudo ufw --force disable
            aviso "Firewall desactivado. Revisalo con calma antes de reintentar."
            pendiente "Configurar UFW: ./setup-security.sh"
        fi
    fi
    marcar_hecho "13-firewall"
fi

# ══ resumen ═══════════════════════════════════════════════════════════════════
echo ""
echo "${B}${C}━━━ Resumen ━━━${N}"
echo ""

CONT=$(sudo docker ps -q 2>/dev/null | wc -l)
echo "  Contenedores arriba: ${B}$CONT${N}"
echo "  IP: ${B}$(hostname -I | awk '{print $1}')${N}"
echo ""
echo "  ${B}Tus servicios:${N}"
for s in homepage grafana prometheus freshrss wallabag pihole news fitbit finance calibre jellyfin radarr prowlarr bazarr qbit; do
    printf "    http://%s.pi\n" "$s"
done

if [ ${#PENDIENTES[@]} -gt 0 ]; then
    echo ""
    echo "  ${A}${B}Te queda pendiente:${N}"
    for p in "${PENDIENTES[@]}"; do echo "    · $p"; done
fi

echo ""
echo "  ${B}Lo que igual vas a tener que hacer a mano:${N}"
echo "    · Crear tu usuario en Grafana, FreshRSS, Wallabag, Jellyfin,"
echo "      Radarr, Prowlarr y Bazarr (la primera vez que entres)"
echo "    · La contrasena temporal de qBittorrent sale con:"
echo "        docker logs qbittorrent 2>&1 | grep -i password"
echo "    · Reautenticar Fitbit y Microsoft Graph desde el navegador"
echo ""
echo "  Documentacion completa en ${B}docs/INDICE.md${N}"
echo ""
echo "  ${A}Y lo mas importante de todo:${N} apaga siempre con ${B}sudo poweroff${N}."
echo "  Cortar la corriente a lo bruto es lo que corrompe la tarjeta."
echo ""
