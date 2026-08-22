#!/bin/bash
# ==============================================================================
#  diagnostico.sh  ·  Que anda, que no, y por que
#
#      ./diagnostico.sh              todo
#      ./diagnostico.sh radarr       un servicio suelto
#      ./diagnostico.sh --breve      solo lo que esta mal
#      ./diagnostico.sh --arreglar   ofrece aplicar los arreglos al final
#
#  Devuelve 0 si esta todo bien y 1 si hay algo mal, asi sirve para correrlo
#  desde una tarea programada.
#
#  COMO PIENSA
#
#  Cada cosa tiene una cadena de eslabones que deben ser ciertos, y el
#  diagnostico se corta en el PRIMERO roto: lo que sigue es consecuencia. Si
#  Pi-hole esta caido fallan los quince nombres .pi, y reportar quince
#  errores esconde el unico que importa.
#
#  REGLAS DE LO QUE IMPRIME
#
#  Lo que esta bien va en una linea y no se explica. Lo que esta mal explica
#  que implica, en una linea. La unica cosa que se permite ocupar mas lugar
#  es un limite, porque ahi el usuario tiene que hacer algo.
#
#  Y cuando se le acaban los caminos, lo dice. Un diagnostico que se calla
#  justo donde no supo que hacer te deja buscando en el lugar equivocado.
#
#  Documentacion:  docs/DIAGNOSTICO.md
# ==============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/comun.sh"

MODO_BREVE=0
MODO_ARREGLAR=0
SOLO=""

for arg in "$@"; do
    case "$arg" in
        --breve|-b)     MODO_BREVE=1 ;;
        --arreglar|-a)  MODO_ARREGLAR=1 ;;
        --ayuda|-h)     sed -n '3,10p' "$0" | sed 's/^# \?//'; exit 0 ;;
        -*)             falla "No conozco la opcion $arg"; exit 1 ;;
        *)              SOLO="$arg" ;;
    esac
done

# ══════════════════════════════════════════════════════════════════════════════
#  VOCABULARIO
#
#  Cinco verbos y nada mas, para que la salida se lea siempre igual:
#
#    bien / ojo / mal   el estado, una linea
#    implica            que significa para vos, una linea
#    arreglo            algo que el script sabe hacer
#    limite             algo que el script NO puede hacer, y por que
# ══════════════════════════════════════════════════════════════════════════════

PROBLEMAS=0
ARREGLOS=()          # "descripcion|funcion|argumento"
LIMITES=()           # "tema|por que no puedo|que te toca"
RAIZ=""              # la causa que explica al resto

bien() {
    [ "$MODO_BREVE" = "1" ] && return 0
    printf "  ${V}●${N} %-21s ${G}%s${N}\n" "$1" "${2:-}"
}
ojo() { printf "  ${A}◐${N} %-21s ${A}%s${N}\n" "$1" "${2:-}"; PROBLEMAS=$((PROBLEMAS+1)); }
mal() { printf "  ${R}✗${N} %-21s ${R}%s${N}\n" "$1" "${2:-}"; PROBLEMAS=$((PROBLEMAS+1)); }

# Que significa el hallazgo. UNA linea, siempre.
implica() { echo "       ${G}implica${N}  $1"; }

# Que se comprobo para llegar hasta aca, cuando no es obvio. UNA linea.
probe()   { echo "       ${G}segun${N}    $1"; }

# Un log solo cuando aporta, y cortado.
evidencia() { $DOCKER logs --tail "${2:-3}" "$1" 2>&1 | tail -"${2:-3}" | sed 's/^/       │ /'; }

arreglo() {
    echo "       ${C}arreglo${N}  $1"
    ARREGLOS+=("$1|$2|${3:-}")
}

# El limite. Tres partes y ninguna de mas: que no puedo, por que, y que te toca.
limite() {
    echo "       ${A}freno${N}    $2"
    [ -n "${3:-}" ] && echo "       ${B}vos${N}      $3"
    LIMITES+=("$1|$2|${3:-}")
}

# Titulo con el objetivo al lado. El objetivo va una vez, no en cada hallazgo.
seccion() {
    [ "$MODO_BREVE" = "1" ] && return 0
    echo ""
    printf "${B}${C}%s${N}  ${G}%s${N}\n" "$1" "$2"
}

# ══════════════════════════════════════════════════════════════════════════════
#  CAPA 0  ·  EL EQUIPO
# ══════════════════════════════════════════════════════════════════════════════

rev_equipo() {
    seccion "El equipo" "· si esto falla, lo de arriba no importa"

    # ── Espacio ──
    local usado libre
    usado=$(df --output=pcent / | tail -1 | tr -dc '0-9')
    libre=$(df -h --output=avail / | tail -1 | tr -d ' ')

    if [ "$usado" -ge 90 ]; then
        mal "disco" "$usado% usado, quedan $libre"
        implica "con el disco lleno las bases de datos se corrompen al escribir"
        RAIZ="el disco esta al $usado%"
        arreglo "borrar imagenes y capas que no usa nadie" "rep_liberar_docker"
    elif [ "$usado" -ge 75 ]; then
        ojo "disco" "$usado% usado, quedan $libre"
        implica "todavia no es urgente, pero conviene mirarlo"
    else
        bien "disco" "$usado% usado, $libre libres"
    fi

    # ── Voltaje: la causa silenciosa. No da error, corrompe escrituras ──
    local thr
    thr=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
    if [ -z "$thr" ]; then
        :
    elif [ "$thr" = "0x0" ]; then
        bien "voltaje" "sin bajones, ni ahora ni desde el arranque"
    else
        mal "voltaje" "$thr"
        implica "el bajo voltaje corrompe escrituras sin dar ningun error"
        limite "la fuente de alimentacion" \
            "es hardware: la fuente no da lo que la Pi 5 pide" \
            "cambiarla por una oficial de 5V y 5A, o sacarle perifericos USB"
    fi

    # ── Temperatura ──
    local temp
    temp=$(vcgencmd measure_temp 2>/dev/null | tr -dc '0-9.' | cut -d. -f1)
    if [ -n "$temp" ]; then
        if [ "$temp" -ge 80 ]; then
            ojo "temperatura" "${temp}°C"
            implica "arriba de 80 la Pi se frena sola"
        else
            bien "temperatura" "${temp}°C"
        fi
    fi

    # ── Sistema de archivos ──
    local dev errores
    dev=$(findmnt -no SOURCE / 2>/dev/null)
    errores=$(sudo dumpe2fs -h "$dev" 2>/dev/null | grep -i "^FS Error count" | tr -dc '0-9')
    if [ "${errores:-0}" != "0" ] && [ -n "$errores" ]; then
        ojo "sistema de archivos" "$errores errores registrados"
        implica "si el contador no crece es dano viejo contenido, si crece es activo"
        limite "reparar el sistema de archivos" \
            "reparar ext4 pide desmontarlo, y la raiz no se desmonta en caliente" \
            "correr 'sudo touch /forcefsck && sudo reboot' cuando estes presente"
    else
        bien "sistema de archivos" "sin errores"
    fi

    # ── Chequeo periodico ──
    local montajes
    montajes=$(sudo tune2fs -l "$dev" 2>/dev/null | grep -i "Maximum mount count" | tr -dc '0-9-')
    if [ "${montajes:-0}" = "-1" ] || [ -z "$montajes" ]; then
        ojo "chequeo del disco" "desactivado"
        implica "un dano se acumula meses sin que nadie se entere, que fue lo que paso"
        arreglo "revisarlo cada 30 arranques" "rep_activar_fsck"
    else
        bien "chequeo del disco" "cada $montajes arranques"
    fi

    # ── log2ram ──
    if systemctl is-active log2ram >/dev/null 2>&1; then
        if mountpoint -q /var/log 2>/dev/null; then
            bien "log2ram" "activo, /var/log en RAM"
        else
            ojo "log2ram" "activo pero /var/log NO esta en RAM"
            implica "sin el montaje no sirve: los logs siguen desgastando la tarjeta"
            arreglo "reiniciarlo" "rep_reiniciar_servicio" "log2ram"
        fi
    else
        ojo "log2ram" "apagado"
        implica "los logs escriben directo a la tarjeta y la desgastan"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  CAPA 1  ·  DNS
# ══════════════════════════════════════════════════════════════════════════════

rev_dns() {
    command -v pihole >/dev/null 2>&1 || return 0
    seccion "DNS" "· si cae, se caen los quince nombres .pi de golpe"

    if ! systemctl is-active pihole-FTL >/dev/null 2>&1; then
        mal "Pi-hole" "el servicio esta caido"
        implica "no resuelve ningun .pi, ni en la Pi ni en el resto de tu red"
        RAIZ="Pi-hole esta caido"
        arreglo "levantarlo" "rep_reiniciar_servicio" "pihole-FTL"
        return 1
    fi

    # Proceso vivo y servicio util no son lo mismo
    local ip
    ip=$(dig +short +time=3 +tries=1 @127.0.0.1 homepage.pi 2>/dev/null | head -1)
    if [ -z "$ip" ]; then
        mal "Pi-hole" "corre pero no resuelve"
        probe "dig @127.0.0.1 homepage.pi no devolvio nada"
        implica "el proceso esta vivo pero no contesta consultas"
        arreglo "reiniciarlo" "rep_reiniciar_servicio" "pihole-FTL"
        RAIZ="Pi-hole no resuelve"
        return 1
    fi
    bien "Pi-hole" "resolviendo, homepage.pi -> $ip"

    local faltantes=() h
    for h in $(hosts_del_caddyfile); do
        dig +short +time=2 +tries=1 @127.0.0.1 "$h" 2>/dev/null | grep -q . || faltantes+=("$h")
    done
    if [ ${#faltantes[@]} -gt 0 ]; then
        ojo "registros .pi" "faltan ${#faltantes[@]}: ${faltantes[*]}"
        implica "Caddy los sirve, pero sin registro el navegador no llega a Caddy"
        arreglo "cargar los que faltan" "rep_dns_faltantes"
    else
        bien "registros .pi" "$(hosts_del_caddyfile | wc -w) nombres, todos resuelven"
    fi

    local escucha
    escucha=$(sudo pihole-FTL --config dns.listeningMode 2>/dev/null | tr -d '"')
    if [ "$escucha" = "LOCAL" ] && command -v tailscale >/dev/null 2>&1; then
        ojo "modo de escucha" "LOCAL, con Tailscale instalado"
        implica "desde afuera de casa las consultas se rechazan, la red de Tailscale se ve ajena"
        arreglo "pasarlo a ALL" "rep_pihole_escucha"
    fi
}

hosts_del_caddyfile() {
    grep -oE '^http://[a-z0-9.]+' "$REPO/caddy/Caddyfile" 2>/dev/null \
        | sed 's|http://||' | grep -v '^$' | sort -u
}

# ══════════════════════════════════════════════════════════════════════════════
#  CAPA 2  ·  CADDY
# ══════════════════════════════════════════════════════════════════════════════

rev_caddy() {
    seccion "La puerta" "· todo el trafico web entra por aca"

    if ! esta_arriba caddy; then
        mal "Caddy" "no esta corriendo"
        implica "no entras a ningun servicio por su nombre, aunque todos anden"
        RAIZ="Caddy esta caido"
        arreglo "levantarlo" "rep_levantar" "caddy"
        return 1
    fi

    if $DOCKER logs --tail 40 caddy 2>&1 | grep -qiE "error|invalid"; then
        ojo "Caddy" "errores en su log"
        evidencia caddy 2
        arreglo "validar y recargar la configuracion" "rep_recargar_caddy"
    else
        bien "Caddy" "sin errores"
    fi

    local h code caidos=()
    for h in $(hosts_del_caddyfile); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -H "Host: $h" "http://$IP_FIJA/" 2>/dev/null)
        case "$code" in 502|000) caidos+=("$h") ;; esac
    done

    if [ ${#caidos[@]} -eq 0 ]; then
        bien "hosts" "$(hosts_del_caddyfile | wc -w) responden"
    else
        ojo "hosts" "${#caidos[@]} en 502: ${caidos[*]}"
        implica "Caddy esta bien, el contenedor de atras no. El problema esta abajo"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  CAPA 3  ·  CADA CONTENEDOR
#
#  El arbol de decision principal. Cada rama termina en un arreglo o en un
#  limite explicito, nunca en un "algo salio mal".
# ══════════════════════════════════════════════════════════════════════════════

revisar_contenedor() {
    local svc="$1" estado salida reinicios edad

    # ── Eslabon 1: existe ──
    if ! $DOCKER ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$svc"; then
        if $DOCKER compose config --services 2>/dev/null | grep -qx "$svc"; then
            mal "$svc" "nunca se levanto"
            arreglo "levantarlo" "rep_levantar" "$svc"
        else
            mal "$svc" "no existe en el repo"
            limite "el servicio $svc" "no esta en ningun docker-compose.yml" "revisar como se escribe"
        fi
        return 1
    fi

    estado=$($DOCKER inspect -f '{{.State.Status}}' "$svc" 2>/dev/null)
    reinicios=$($DOCKER inspect -f '{{.RestartCount}}' "$svc" 2>/dev/null)

    # ── Eslabon 2: corre ──
    if [ "$estado" != "running" ]; then
        salida=$($DOCKER inspect -f '{{.State.ExitCode}}' "$svc" 2>/dev/null)
        mal "$svc" "$estado, salio con codigo $salida"
        case "$salida" in
            137)
                implica "codigo 137 es el sistema matandolo por falta de memoria"
                limite "la memoria" \
                    "volver a subirlo sin cambiar nada lo va a matar de nuevo" \
                    "bajarle el mem_limit a otro contenedor, o levantar menos cosas juntas"
                ;;
            0)
                implica "termino solo y sin error, puede ser normal si es una tarea"
                arreglo "levantarlo" "rep_levantar" "$svc"
                ;;
            *)
                evidencia "$svc" 3
                arreglo "intentar levantarlo" "rep_levantar" "$svc"
                ;;
        esac
        return 1
    fi

    # ── Eslabon 3: bucle de reinicios ──
    if [ "${reinicios:-0}" -gt 5 ]; then
        mal "$svc" "reinicio $reinicios veces"
        implica "arranca y se cae solo, asi que levantarlo de nuevo no arregla nada"
        evidencia "$svc" 4
        limite "el bucle de $svc" \
            "ese log es todo lo que tengo, y no se leerlo por vos" \
            "suele ser una variable mal puesta o un archivo que falta"
        return 1
    fi

    # ── Eslabon 4: contesta ──
    local puerto; puerto=$(puerto_de "$svc")
    [ -n "$puerto" ] || { bien "$svc" "corriendo"; return 0; }

    # Se pregunta DESDE EL HOST a la IP del contenedor, no con docker exec curl.
    # La mitad de las imagenes no traen curl, y ahi el exec falla con un texto
    # que se colaba como si fuera un codigo HTTP: decia "responde" sin haber
    # comprobado nada, que es el peor error que puede cometer un diagnostico.
    local ip code
    ip=$($DOCKER inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$svc" 2>/dev/null | awk '{print $1}')
    if [ -z "$ip" ]; then
        bien "$svc" "corriendo, sin IP para consultar"
        return 0
    fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$ip:$puerto/" 2>/dev/null)
    edad=$(segundos_desde "$($DOCKER inspect -f '{{.State.StartedAt}}' "$svc" 2>/dev/null)")

    case "$code" in
        ""|000)
            if [ "$edad" -lt 120 ]; then
                ojo "$svc" "sin contestar, arranco hace ${edad}s"
                implica "puede ser normal, volve a correr esto en un minuto"
            else
                mal "$svc" "no contesta en el puerto $puerto"
                implica "lleva ${edad}s arriba, ya deberia estar listo"
                evidencia "$svc" 3
                arreglo "recrearlo" "rep_recrear" "$svc"
            fi
            return 1 ;;
        5*)
            if [ "$edad" -lt 180 ]; then
                ojo "$svc" "arrancando, HTTP $code hace ${edad}s"
                implica "Jellyfin y los *arr dan 503 un rato antes de estar listos"
            else
                mal "$svc" "HTTP $code despues de ${edad}s"
                evidencia "$svc" 3
                arreglo "recrearlo" "rep_recrear" "$svc"
            fi
            return 1 ;;
    esac

    bien "$svc" "responde, HTTP $code"
}

puerto_de() {
    case "$1" in
        caddy) echo 80 ;;
        homepage|grafana) echo 3000 ;;
        prometheus) echo 9090 ;;
        freshrss|wallabag) echo 80 ;;
        news-filter-ui) echo 8084 ;;
        finance-tracker-ui) echo 8085 ;;
        fitbit-exporter-ui) echo 8086 ;;
        jellyfin) echo 8096 ;;
        qbittorrent) echo 8080 ;;
        prowlarr) echo 9696 ;;
        radarr) echo 7878 ;;
        bazarr) echo 6767 ;;
        *) echo "" ;;
    esac
}

segundos_desde() {
    local t; t=$(date -d "$1" +%s 2>/dev/null) || { echo 99999; return; }
    echo $(( $(date +%s) - t ))
}

# ══════════════════════════════════════════════════════════════════════════════
#  CAPA 4  ·  PUEDE HACER SU TRABAJO?
#
#  Un servicio que responde no es un servicio que sirve.
# ══════════════════════════════════════════════════════════════════════════════

rev_media() {
    esta_arriba radarr || esta_arriba jellyfin || return 0
    seccion "Multimedia" "· responde no es lo mismo que puede trabajar"

    if das_montado; then
        bien "el disco" "montado en $(das_ruta), $(das_libre) libres"
    else
        mal "el disco" "no hay disco externo"
        implica "$(das_ruta) esta en la tarjeta del sistema, con $(das_libre) libres"
        RAIZ="el DAS no esta montado"
        if descargas_en_pausa; then
            probe "las descargas estan en pausa, asi que por ahora no hay riesgo"
        else
            arreglo "pausar las descargas hasta que conectes el disco" "rep_pausar_descargas"
        fi
        limite "montar el disco" \
            "no hay ningun disco externo conectado, y eso es fisico" \
            "conectarlo y seguir media/DAS.md"
    fi

    if esta_arriba prowlarr; then
        local n
        n=$(arr_api prowlarr 9696 v1 GET /indexer 2>/dev/null | grep -o '"id"' | wc -l)
        if [ "${n:-0}" -eq 0 ]; then
            ojo "Prowlarr" "0 indexers"
            implica "anda perfecto pero no puede buscar nada, y Radarr tampoco"
            limite "cargar indexers" \
                "que trackers usas es tuyo, y varios piden cuenta propia" \
                "http://prowlarr.pi, Indexers, Add Indexer"
        else
            bien "Prowlarr" "$n indexers"
        fi
    fi

    if esta_arriba radarr; then
        local raices clientes idx
        raices=$(arr_api radarr 7878 v3 GET /rootfolder 2>/dev/null | grep -o '"path"' | wc -l)
        clientes=$(arr_api radarr 7878 v3 GET /downloadclient 2>/dev/null | grep -o '"protocol"' | wc -l)
        idx=$(arr_api radarr 7878 v3 GET /indexer 2>/dev/null | grep -o '"id"' | wc -l)
        if [ "${raices:-0}" -eq 0 ]; then
            ojo "Radarr" "sin carpeta raiz"
            implica "no sabe donde guardar las peliculas"
            arreglo "configurarlo" "rep_configurar_radarr"
        elif [ "${clientes:-0}" -eq 0 ]; then
            ojo "Radarr" "sin cliente de descargas"
            implica "encuentra peliculas pero no tiene con que bajarlas"
            arreglo "conectar qBittorrent" "rep_configurar_radarr"
        elif [ "${idx:-0}" -eq 0 ]; then
            ojo "Radarr" "0 indexers sincronizados"
            implica "consecuencia de que Prowlarr no tenga ninguno"
        else
            bien "Radarr" "carpeta, cliente y $idx indexers"
        fi
    fi

    if esta_arriba bazarr; then
        local perfiles
        perfiles=$($DOCKER exec bazarr sh -c 'grep -c "enabled_languages" /config/config/config.yaml' 2>/dev/null)
        if [ "${perfiles:-0}" -eq 0 ]; then
            ojo "Bazarr" "sin perfil de idiomas"
            implica "es el paso que mas se olvida: sin perfil no baja ningun subtitulo"
            limite "armar el perfil" \
                "que idiomas queres es una eleccion tuya" \
                "http://bazarr.pi, Settings, Languages, agregar y crear un perfil"
        else
            bien "Bazarr" "con perfil de idiomas"
        fi
    fi

    if esta_arriba jellyfin; then
        local n
        n=$($DOCKER exec jellyfin sh -c 'ls /media/movies 2>/dev/null | wc -l' 2>/dev/null)
        if [ "${n:-0}" -eq 0 ]; then
            ojo "Jellyfin" "biblioteca vacia"
            implica "normal si todavia no bajaste nada o falta el disco"
        else
            bien "Jellyfin" "$n elementos"
        fi
    fi
}

descargas_en_pausa() {
    $DOCKER exec qbittorrent sh -c \
        'grep -qiE "AddTorrentStopped=true|StartInPause=true" /config/qBittorrent/qBittorrent.conf' 2>/dev/null
}

rev_monitoreo() {
    esta_arriba prometheus || return 0
    seccion "Monitoreo" "· que las metricas lleguen, no solo que el grafico exista"

    local caidos
    caidos=$($DOCKER exec prometheus sh -c \
        'wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null' 2>/dev/null \
        | grep -o '"health":"down"' | wc -l)
    if [ "${caidos:-0}" -gt 0 ]; then
        [ "$caidos" = "1" ] && ojo "Prometheus" "1 objetivo caido" || ojo "Prometheus" "$caidos objetivos caidos"
        implica "los graficos de esas fuentes van a estar vacios"
    else
        bien "Prometheus" "todos los objetivos responden"
    fi
}

rev_tokens() {
    esta_arriba fitbit-exporter || esta_arriba itau-email-tracker || return 0
    seccion "Datos personales" "· los permisos vencen solos y nadie avisa"

    if esta_arriba fitbit-exporter; then
        if ! archivo_completo "fitbit-exporter/tokens.json" "YOUR_CLIENT_ID"; then
            ojo "Fitbit" "sin credenciales"
            limite "autorizar Fitbit" \
                "pide entrar con tu cuenta en un navegador" \
                "seguir fitbit-exporter/README.md"
        elif $DOCKER logs --tail 30 fitbit-exporter 2>&1 | grep -qiE "401|unauthorized|invalid_grant"; then
            mal "Fitbit" "el permiso vencio"
            implica "el contenedor corre pero no baja un solo dato"
            limite "renovar el permiso" \
                "renovarlo pide tu cuenta en un navegador" \
                "volver a correr la autorizacion de fitbit-exporter/README.md"
        else
            bien "Fitbit" "con permiso vigente"
        fi
    fi

    if esta_arriba itau-email-tracker; then
        if ! archivo_completo "finance/finance-tracker/data/token.json" ""; then
            ojo "Finanzas" "sin token de Microsoft"
            limite "autorizar el correo" \
                "pide tu cuenta de Microsoft en un navegador" \
                "seguir finance/finance-tracker/README.md"
        elif $DOCKER logs --tail 30 itau-email-tracker 2>&1 | grep -qiE "401|unauthorized|invalid_grant"; then
            mal "Finanzas" "el permiso vencio"
            implica "corre pero no lee un solo mail"
            limite "renovar el permiso" "pide tu cuenta en un navegador" \
                "volver a autorizar segun finance/finance-tracker/README.md"
        else
            bien "Finanzas" "con permiso vigente"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  CAPA 5  ·  LOS NATIVOS
# ══════════════════════════════════════════════════════════════════════════════

rev_nativos() {
    seccion "Fuera de Docker" "· lo que sigue en pie aunque Docker se caiga"

    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        if systemctl is-active fail2ban >/dev/null 2>&1; then
            bien "firewall" "UFW y fail2ban activos"
        else
            ojo "firewall" "UFW si, fail2ban no"
            implica "nada frena los intentos de fuerza bruta contra SSH"
            arreglo "levantar fail2ban" "rep_reiniciar_servicio" "fail2ban"
        fi
    else
        ojo "firewall" "UFW desactivado"
        implica "todos los puertos de la Pi quedan abiertos en tu red"
    fi

    if command -v tailscale >/dev/null 2>&1; then
        if sudo tailscale status >/dev/null 2>&1; then
            # La aprobacion de la ruta se decide en la consola de Tailscale y
            # no hay forma de consultarla desde aca, asi que se aclara y listo.
            bien "Tailscale" "conectado como $(sudo tailscale ip -4 2>/dev/null | head -1), ruta sin verificar"
        else
            ojo "Tailscale" "instalado, sin conectar"
            limite "conectar Tailscale" \
                "autenticar abre una URL que se aprueba con tu cuenta" \
                "correr 'sudo tailscale up' y abrir el enlace"
        fi
    fi

    if command -v calibre-server >/dev/null 2>&1; then
        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
        if systemctl --user is-active calibre-server >/dev/null 2>&1; then
            bien "Calibre" "corriendo en el 8083"
        else
            ojo "Calibre" "instalado pero apagado"
            arreglo "levantarlo" "rep_calibre"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  LOS ARREGLOS
#
#  Tres condiciones para estar aca: reversible, no destruye datos, y se
#  verifica despues. Un arreglo que dice haber andado sin comprobarlo es
#  peor que no tenerlo.
# ══════════════════════════════════════════════════════════════════════════════

rep_levantar() { $DOCKER compose up -d "$1" >/dev/null 2>&1; sleep 4; olvidar_estado; esta_arriba "$1"; }
rep_recrear()  { $DOCKER compose up -d --force-recreate "$1" >/dev/null 2>&1; sleep 6; olvidar_estado; esta_arriba "$1"; }

rep_reiniciar_servicio() {
    sudo systemctl restart "$1" >/dev/null 2>&1
    sleep 3
    systemctl is-active "$1" >/dev/null 2>&1
}

rep_calibre() {
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    sudo loginctl enable-linger "$USER" 2>/dev/null
    systemctl --user enable --now calibre-server 2>/dev/null
    sleep 3
    systemctl --user is-active calibre-server >/dev/null 2>&1
}

rep_liberar_docker() {
    local antes despues
    antes=$(df --output=avail / | tail -1 | tr -dc '0-9')
    $DOCKER image prune -f >/dev/null 2>&1
    $DOCKER builder prune -f >/dev/null 2>&1
    despues=$(df --output=avail / | tail -1 | tr -dc '0-9')
    info "Recupere $(( (despues - antes) / 1024 )) MB"
    [ "$despues" -ge "$antes" ]
}

rep_activar_fsck() { sudo tune2fs -c 30 "$(findmnt -no SOURCE /)" >/dev/null 2>&1; }

rep_recargar_caddy() {
    if $DOCKER exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
        $DOCKER exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1
    else
        falla "El Caddyfile no valida, no lo recargo para no dejarte sin HTTP"
        $DOCKER exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | head -3 | sed 's/^/       │ /'
        return 1
    fi
}

rep_dns_faltantes() {
    local H="[" h
    for h in $(hosts_del_caddyfile); do H="$H\"$IP_FIJA $h\","; done
    sudo pihole-FTL --config dns.hosts "${H%,}]" >/dev/null 2>&1
    sudo systemctl restart pihole-FTL >/dev/null 2>&1
    sleep 3
    dig +short +time=3 @127.0.0.1 homepage.pi 2>/dev/null | grep -q .
}

rep_pihole_escucha() {
    sudo pihole-FTL --config dns.listeningMode ALL >/dev/null 2>&1
    sudo systemctl restart pihole-FTL >/dev/null 2>&1
    sleep 3
    systemctl is-active pihole-FTL >/dev/null 2>&1
}

# Pausa sin necesitar la contrasena de la WebUI: se escribe en su
# configuracion con el contenedor parado, porque andando la reescribe al salir.
rep_pausar_descargas() {
    local cfg; cfg=$(ruta_config qbittorrent)
    if [ -z "$cfg" ] || ! sudo test -f "$cfg/qBittorrent/qBittorrent.conf"; then
        falla "No encontre la configuracion de qBittorrent"
        return 1
    fi
    $DOCKER stop qbittorrent >/dev/null 2>&1
    sudo cp "$cfg/qBittorrent/qBittorrent.conf" "$cfg/qBittorrent/qBittorrent.conf.previo"
    sudo sed -i '/AddTorrentStopped/d;/StartInPause/d' "$cfg/qBittorrent/qBittorrent.conf"
    if sudo grep -q "^\[BitTorrent\]" "$cfg/qBittorrent/qBittorrent.conf"; then
        sudo sed -i 's|^\[BitTorrent\]|[BitTorrent]\nSession\\AddTorrentStopped=true|' "$cfg/qBittorrent/qBittorrent.conf"
    else
        printf '\n[BitTorrent]\nSession\\AddTorrentStopped=true\n' | sudo tee -a "$cfg/qBittorrent/qBittorrent.conf" >/dev/null
    fi
    $DOCKER start qbittorrent >/dev/null 2>&1
    esperar_http qbittorrent 8080 >/dev/null 2>&1
    descargas_en_pausa
}

rep_configurar_radarr() {
    pedir_clave_maestra
    cfg_radarr "$CLAVE_MAESTRA"
}

# ══════════════════════════════════════════════════════════════════════════════
#  CIERRE
# ══════════════════════════════════════════════════════════════════════════════

aplicar_arreglos() {
    [ ${#ARREGLOS[@]} -eq 0 ] && return 0
    echo ""
    titulo "Puedo arreglar ${#ARREGLOS[@]} de estas"
    local linea desc fn arg
    for linea in "${ARREGLOS[@]}"; do
        IFS='|' read -r desc fn arg <<< "$linea"
        echo "  ${C}·${N} $desc"
    done
    echo ""
    gris "  Todos son reversibles y ninguno borra datos."

    if [ "$MODO_ARREGLAR" != "1" ]; then
        echo ""
        info "Para aplicarlos:  ${B}./diagnostico.sh --arreglar${N}"
        return 0
    fi

    echo ""
    preguntar "¿Los aplico?" "s" || return 0
    echo ""
    for linea in "${ARREGLOS[@]}"; do
        IFS='|' read -r desc fn arg <<< "$linea"
        info "$desc"
        if "$fn" "$arg"; then
            ok "hecho y verificado"
        else
            falla "no funciono"
            gris "     volve a correr el diagnostico para ver si el sintoma cambio"
        fi
    done
}

resumen_final() {
    echo ""
    if [ "$PROBLEMAS" -eq 0 ]; then
        titulo "Todo bien"
        ok "No encontre nada roto."
        return 0
    fi

    titulo "En resumen"
    echo "  ${B}$PROBLEMAS${N} cosas para mirar."
    if [ -n "$RAIZ" ]; then
        echo ""
        aviso "La causa de fondo parece ser: ${B}$RAIZ${N}"
        gris "     Arreglando eso, varios de los otros probablemente se vayan solos."
    fi

    if [ ${#LIMITES[@]} -gt 0 ]; then
        echo ""
        echo "  ${A}${B}Lo que yo no puedo hacer${N}"
        gris "     Necesitan un navegador, una cuenta tuya, hardware, o una decision."
        echo ""
        local linea tema porque tuyo
        for linea in "${LIMITES[@]}"; do
            IFS='|' read -r tema porque tuyo <<< "$linea"
            echo "  ${B}·${N} ${C}$tema${N}"
            gris "      $porque"
            [ -n "$tuyo" ] && echo "      ${B}vos${N}  $tuyo"
        done
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════

if ! sudo -n true 2>/dev/null; then
    falla "sudo pide contrasena y el diagnostico la necesita para mirar el disco."
    exit 1
fi

if [ -n "$SOLO" ]; then
    titulo "Diagnostico de $SOLO"
    revisar_contenedor "$SOLO"
else
    echo ""
    echo "${B}${C}  Diagnostico de Pi-Services${N}"
    gris "  Se corta en el primer eslabon roto: lo que sigue suele ser consecuencia."

    rev_equipo
    rev_dns
    rev_caddy

    seccion "Los contenedores" "· que existan, corran y contesten"
    for s in $($DOCKER ps -a --format '{{.Names}}' 2>/dev/null | sort); do
        [ "$s" = "caddy" ] && continue
        revisar_contenedor "$s"
    done

    rev_media
    rev_monitoreo
    rev_tokens
    rev_nativos
fi

aplicar_arreglos
resumen_final
[ "$PROBLEMAS" -eq 0 ]
