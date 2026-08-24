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

# Todo lo que sabe sobre los servicios vive aparte, para que el diagnostico
# use exactamente lo mismo. Ver lib/comun.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/comun.sh"

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

# Imprime una lista de variables faltantes, agrupadas por modulo.
#
# Se ordena antes de agrupar. Comparando solo contra la fila anterior, dos
# datos del mismo modulo separados por uno de otro imprimian el titulo del
# modulo dos veces, como si fueran grupos distintos.
listar_faltantes() {
    local mod_previo="" linea m arch v tipo desc ayuda
    local ordenadas=()
    while IFS= read -r linea; do ordenadas+=("$linea"); done < <(printf '%s\n' "$@" | sort -t'|' -k1,1 -s)

    for linea in "${ordenadas[@]}"; do
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
        # El detalle de lo que ya anda, y para que sirve lo que todavia no.
        # Estas explicaciones estaban escritas y nunca se mostraban, asi que
        # habia que saber de antemano que es Prowlarr para poder elegirlo.
        if [ "${ESTADO[$mod]}" = "activo" ]; then
            [ -n "${DETALLE[$mod]:-}" ] && gris "        ${DETALLE[$mod]}"
        else
            gris "        ${DESCRIPCION[$mod]}"
            [ -n "${DETALLE[$mod]:-}" ] && gris "        ahora: ${DETALLE[$mod]}"
        fi
        i=$((i+1))
    done

    echo ""
    gris "  ● funcionando    ◐ incompleto    ○ sin instalar"
    echo ""
    info "Escribi los numeros separados por espacio.  Ejemplo:  1 2 3 5"
    info "O escribi:  ${B}todo${N}  ·  ${B}faltantes${N} (solo lo incompleto o sin instalar)"
    info "Para salir sin tocar nada:  ${B}salir${N}"
    echo ""

    # Se vuelve a preguntar hasta entender. Antes, un tipeo cualquiera daba
    # una seleccion vacia y el instalador se cerraba sin explicar por que.
    local resp intentos=0
    while true; do
        intentos=$((intentos+1))
        read -r -p "  ${B}Tu eleccion:${N} " resp </dev/tty

        SELECCION=()
        case "$resp" in
            salir|q|Q) info "Listo, no toco nada."; exit 0 ;;
            todo) SELECCION=("${MODULOS[@]}") ;;
            faltantes)
                for mod in "${MODULOS[@]}"; do
                    [ "${ESTADO[$mod]}" != "activo" ] && SELECCION+=("$mod")
                done
                [ ${#SELECCION[@]} -eq 0 ] && { ok "No hay nada incompleto: ya esta todo."; exit 0; }
                ;;
            *)
                local n malos=""
                for n in $resp; do
                    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#INDICE[@]}" ]; then
                        SELECCION+=("${INDICE[$((n-1))]}")
                    else
                        malos="$malos $n"
                    fi
                done
                [ -n "$malos" ] && aviso "No entendi:${B}$malos${N}. Van numeros del 1 al ${#INDICE[@]}."
                ;;
        esac

        [ ${#SELECCION[@]} -gt 0 ] && break
        [ "$intentos" -ge 3 ] && { falla "Salgo sin tocar nada."; exit 0; }
        aviso "No elegiste nada valido. Probá de nuevo."
    done

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

# Modulos cuyo .env cambio y por lo tanto hay que recrear. Cambiar el archivo
# no alcanza: el contenedor ya levantado tiene los valores viejos en memoria.
RECREAR_POR_CLAVE=()

recrear_por_clave() {
    [ ${#RECREAR_POR_CLAVE[@]} -eq 0 ] && return 0
    local mod svcs vistos=" " todos=""
    for mod in "${RECREAR_POR_CLAVE[@]}"; do
        [[ "$vistos" == *" $mod "* ]] && continue
        vistos="$vistos$mod "
        svcs=$(servicios_elegidos "$mod")
        [ -n "$svcs" ] && todos="$todos $svcs"
    done
    [ -n "$todos" ] || return 0
    echo ""
    info "Recreo los contenedores que usan las contrasenas nuevas."
    gris "     Cambiar el .env no alcanza: los tienen cargados en memoria."
    # shellcheck disable=SC2086
    $DOCKER compose up -d --force-recreate $todos >/dev/null 2>&1
    olvidar_estado
    sleep 4
    ok "Listos"
}

# Las contrasenas que YA estaban cargadas en los .env no se tocaban nunca,
# porque completa() las daba por buenas y recolectar solo pide lo que falta.
# El resultado era que cambiar la contrasena general dejaba la homepage y los
# tres paneles propios con la vieja: los dos mundos que este instalador vino a
# unificar, otra vez separados y sin que nadie avise.
actualizar_claves_existentes() {
    local linea m arch v tipo desc ayuda ya=()

    for linea in "${VARIABLES[@]}"; do
        IFS='|' read -r m arch v tipo desc ayuda <<< "$linea"
        [[ " ${SELECCION[*]} " == *" $m "* ]] || continue
        case "$tipo" in clave|hash) ;; *) continue ;; esac
        completa "$arch" "$v" || continue      # las vacias ya se piden aparte
        ya+=("$linea")
    done
    [ ${#ya[@]} -eq 0 ] && return 0

    # Sin contrasena nueva no hay nada que unificar
    [ -n "$CLAVE_MAESTRA" ] || return 0
    unificar_claves || return 0

    local nueva hash
    for linea in "${ya[@]}"; do
        IFS='|' read -r m arch v tipo desc ayuda <<< "$linea"
        nueva=$(clave_para "$desc")
        if [ "$tipo" = "hash" ]; then
            info "Generando el hash de $desc, bcrypt es lento a proposito..."
            hash=$($DOCKER run --rm caddy:2-alpine caddy hash-password --plaintext "$nueva" 2>/dev/null)
            if [ -z "$hash" ]; then
                aviso "No se pudo generar el hash de $desc"
                pendiente "Actualizar $v en $arch"
                continue
            fi
            # Cada $ va duplicado o Docker Compose lo toma por variable
            escribir_var "$arch" "$v" "${hash//\$/\$\$}"
        else
            escribir_var "$arch" "$v" "$nueva"
        fi
        ok "$desc actualizada"
        RECREAR_POR_CLAVE+=("$m")
    done
}

# ¿Este dato solo existe despues de crear una cuenta? Si es asi no tiene
# sentido pedirlo antes de que el servicio exista.
sale_de_una_cuenta() {
    local arch="$1" var="$2" t ta tv
    for t in "${TOKENS_DE_CUENTA[@]}"; do
        IFS='|' read -r _ _ ta tv _ _ <<< "$t"
        [ "$ta" = "$arch" ] && [ "$tv" = "$var" ] && return 0
    done
    return 1
}

avisar_dependencias() {
    local elegidos="$1" linea srv deps motivo faltan d
    for linea in "${DEPENDENCIAS[@]}"; do
        IFS='|' read -r srv deps motivo <<< "$linea"
        [[ " $elegidos " == *" $srv "* ]] || continue
        faltan=""
        for d in $deps; do
            # Si no lo elegiste y tampoco esta corriendo, falta
            if [[ " $elegidos " != *" $d "* ]] && ! esta_arriba "$d"; then
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
            esta_arriba "$s" && marca="${V}●${N}"
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

    # Ahora los que necesitan al usuario.
    #
    # Salvo los que salen de una cuenta que todavia no existe: en una maquina
    # limpia, cuatro de las siete preguntas eran imposibles de contestar,
    # porque el dato vive en el panel de un servicio que ni siquiera esta
    # levantado. La unica respuesta posible era Enter, cuatro veces, cada una
    # con su aviso amarillo de "salteado". Esos se piden al final, en la guia
    # de cuentas, que es el momento en que existen.
    local faltantes=() para_despues=0
    for linea in "${VARIABLES[@]}"; do
        IFS='|' read -r m arch v tipo desc ayuda <<< "$linea"
        [[ " ${SELECCION[*]} " == *" $m "* ]] || continue
        [ "$tipo" = "auto" ] && continue
        completa "$arch" "$v" && continue
        if [ "$tipo" = "token" ] && sale_de_una_cuenta "$arch" "$v"; then
            para_despues=$((para_despues+1))
            continue
        fi
        faltantes+=("$linea")
    done

    if [ "$para_despues" -gt 0 ]; then
        echo ""
        info "$para_despues $(plural "$para_despues" "dato sale" "datos salen") de cuentas que todavia no existen."
        gris "     Te $(plural "$para_despues" "lo pido" "los pido") al final, cuando las hayas creado."
    fi

    if [ ${#faltantes[@]} -eq 0 ]; then
        echo ""; ok "No falta ningun dato mas. Todo lo necesario ya estaba cargado."
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
    actualizar_claves_existentes

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
        # Se comprueba que quedo, no que el comando no dio error. Sin internet
        # el instalador remoto falla y con toda la salida a /dev/null el visto
        # verde salia igual, que es la peor forma de mentir: convincente.
        if ! command -v docker >/dev/null 2>&1; then
            falla "No se pudo instalar Docker"
            info "Suele ser falta de internet. Probá:  ping -c1 get.docker.com"
            pendiente "Instalar Docker y volver a correr el instalador"
            return 1
        fi
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
        if [ ! -f /etc/log2ram.conf ]; then
            aviso "No se pudo instalar log2ram"
            gris "     sin el, los logs escriben directo a la tarjeta y la desgastan"
            pendiente "Instalar log2ram: fallo la descarga, revisá la conexion"
        else
            sudo sed -i 's|^SIZE=.*|SIZE=512M|' /etc/log2ram.conf 2>/dev/null
            ok "log2ram instalado"
            pendiente "Reiniciar para que log2ram tome efecto"
        fi
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
        # Los registros se recargan igual. Si no, agregar un servicio nuevo
        # dejaba su nombre sin resolver para siempre, porque este return
        # temprano se saltea todo lo de abajo y nadie vuelve a mirarlo.
        cargar_registros_dns
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
        if ! command -v pihole >/dev/null 2>&1; then
            falla "No se pudo instalar Pi-hole"
            pendiente "Instalar Pi-hole: fallo el instalador remoto, revisá la conexion"
            return 1
        fi
        ok "Pi-hole instalado"| sudo bash /dev/stdin --unattended
        ok "Pi-hole instalado"
    fi

    # Liberar el 80 para Caddy
    if sudo pihole-FTL --config webserver.port 2>/dev/null | grep -q "^80o"; then
        sudo pihole-FTL --config webserver.port "8181o,[::]:8181o" >/dev/null
        sudo systemctl restart pihole-FTL
        ok "Panel movido al 8181, el 80 queda libre para Caddy"
    fi

    cargar_registros_dns

    elegir_blocklists

    if [ -z "$(sudo pihole-FTL --config webserver.api.pwhash 2>/dev/null | tr -d '"')" ]; then
        aviso "Pi-hole quedo sin contrasena: su panel es accesible desde tu LAN"
        pendiente "Poner contrasena a Pi-hole:  sudo pihole setpassword"
    fi
}

# Baja las imagenes de a una. En paralelo satura la SD y se cuelga sin dar
# error, dejando capas escritas a medias que despues rompen contenedores.
# Solo las imagenes de los servicios que elegiste.
#
# Antes miraba el compose entero y se bajaba las 14 imagenes del repo, o sea
# 6,27 GB, aunque hubieras elegido un solo modulo. En una tarjeta de 29 GB eso
# es media tarjeta en cosas que nadie pidio, y llenarla es lo que la corrompe.
bajar_imagenes() {
    local mod="$1" img imgs faltan=0 libre
    local svcs; svcs=$(servicios_elegidos "$mod")
    [ -n "$svcs" ] || return 0

    imgs=$(SVC="$svcs" $DOCKER compose config --format json 2>/dev/null | python3 -c '
import sys, json, os
elegidos = set(os.environ.get("SVC", "").split())
d = json.load(sys.stdin)
imgs = {v["image"] for k, v in d.get("services", {}).items()
        if k in elegidos and "image" in v}
print("\n".join(sorted(imgs)))' 2>/dev/null)

    # Si el filtro no anduvo, mejor no bajar nada: el up las trae solas.
    [ -n "$imgs" ] || return 0

    for img in $imgs; do
        $DOCKER image inspect "$img" >/dev/null 2>&1 || faltan=$((faltan+1))
    done
    [ "$faltan" -eq 0 ] && return 0

    # Un aviso antes de ocupar disco, no despues
    libre=$(df -h --output=avail / | tail -1 | tr -d ' ')
    info "Faltan $faltan imagenes. Quedan $libre libres en la tarjeta."

    for img in $imgs; do
        if ! $DOCKER image inspect "$img" >/dev/null 2>&1; then
            info "bajando $img"
            $DOCKER pull "$img" >/dev/null 2>&1 || {
                aviso "fallo la descarga de $img"
                pendiente "Bajar la imagen $img (fallo la descarga, revisa la conexion)"
            }
        fi
    done
}

levantar_modulo() {
    local mod="$1"
    local servicios; servicios=$(servicios_elegidos "$mod")
    [ -n "$servicios" ] || return 0

    # La red tiene que existir ANTES. Ocho composes la declaran como externa
    # porque estan pensados para poder correr sueltos; si no existe, el up
    # construye todo durante una hora y recien al final falla sin levantar nada.
    #
    # Se comprueba en cada modulo, no una sola vez al principio: asi da igual
    # que levantes dos modulos hoy y tres el mes que viene.
    if ! $DOCKER network ls --format '{{.Name}}' 2>/dev/null | grep -qx "pi-services"; then
        $DOCKER network create pi-services >/dev/null 2>&1
        ok "Red 'pi-services' creada"
    fi

    # Los que ya estan corriendo no se tocan
    local pendientes="" s
    for s in $servicios; do
        if esta_arriba "$s"; then
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
    olvidar_estado

    sleep 4
    local arriba=0 total=0
    for s in $servicios; do
        total=$((total+1))
        esta_arriba "$s" && arriba=$((arriba+1))
    done
    if [ "$arriba" -eq "$total" ]; then
        ok "$arriba de $total contenedores arriba"
    else
        aviso "$arriba de $total arriba"
        for s in $servicios; do
            esta_arriba "$s" || \
                gris "     no levanto: $s   ·   ver con: docker compose logs $s"
        done
        pendiente "Revisar los contenedores de ${NOMBRE[$mod]} que no levantaron"
    fi
}

instalar_tailscale() {
    if [ "${ESTADO[tailscale]}" = "activo" ]; then ok "Ya estaba conectado"; return; fi
    command -v tailscale >/dev/null 2>&1 || { info "Instalando..."; curl -fsSL https://tailscale.com/install.sh | sudo sh >/dev/null 2>&1; }
    if ! command -v tailscale >/dev/null 2>&1; then
        falla "No se pudo instalar Tailscale"
        info "Suele ser falta de internet. Probá:  ping -c1 tailscale.com"
        pendiente "Instalar Tailscale: fallo el instalador remoto"
        return 1
    fi
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

    # Los servicios que Caddy alcanza en el host, solo desde las redes de
    # Docker. El orden importa: UFW aplica la primera regla que coincide, asi
    # que los ALLOW tienen que ir antes que los DENY.
    #
    # Cuales son sale del Caddyfile, no de una lista: cuando se sumo Home
    # Assistant, la lista escrita a mano seguia teniendo solo el 8181 y Caddy
    # contestaba 502 sin que nada dijera que era el firewall.
    local red puerto n=0
    for puerto in $(puertos_del_host); do
        for red in 172.17.0.0/16 172.18.0.0/16 172.19.0.0/16 172.20.0.0/16; do
            sudo ufw allow from $red to any port "$puerto" proto tcp >/dev/null 2>&1
        done
        sudo ufw --force delete deny "$puerto" >/dev/null 2>&1
        sudo ufw deny "$puerto"/tcp >/dev/null 2>&1
        n=$((n+1))
    done
    ok "Reglas aplicadas: $n $(plural "$n" "puerto del host cerrado" "puertos del host cerrados") salvo para Caddy"

    echo ""
    aviso "Abri OTRA terminal y proba AHORA que seguis entrando por SSH."
    gris "     Sin cerrar esta. Si algo salio mal, esta sesion es tu unica via."
    echo ""
    # La respuesta por defecto es NO a proposito. Antes era que si, o sea que
    # apretar Enter sin haber probado nada dejaba el firewall activo, que es
    # justo el caso en que te quedas afuera. Con el default en no, distraerse
    # sale barato: el firewall se apaga y lo volves a intentar.
    if preguntar "¿Entraste bien desde la otra terminal?" "n"; then
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
            tailscale)  instalar_tailscale ;;
            seguridad)  instalar_seguridad ;;
            *)
                # levantar_modulo respeta los servicios elegidos y saltea
                # los que ya estan corriendo, asi que es seguro llamarlo
                # siempre: no reinicia nada que ya funcione.
                bajar_imagenes "$mod"
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

# Solo lo que NO se puede automatizar: crear una cuenta desde cero, y las
# elecciones que son tuyas (que indexers usas, en que idioma queres los
# subtitulos). Todo lo demas lo dejo hecho antes de llegar aca.
#
# modulo|servicio|url|de que se trata
CUENTAS=(
"monitoring|pihole|http://pihole.pi|Generar la clave de API para las metricas"
"news|freshrss|http://freshrss.pi|Crear tu cuenta y habilitar la API"
"news|wallabag|http://wallabag.pi|Cambiar la contrasena y crear el cliente de API"
"media|prowlarr|http://prowlarr.pi|Cargar los indexers que uses"
"media|bazarr|http://bazarr.pi|Elegir idiomas y proveedores de subtitulos"
"media|jellyfin|http://jellyfin.pi|Instalar los complementos"
)

# El paso a paso de cada uno, una linea por paso.
declare -A PASOS=(
[pihole]="Entra con tu contrasena de Pi-hole.
${B}Settings${N}, arriba a la derecha pasa el modo a ${B}Expert${N}.
Despues ${B}Settings, API / Web interface${N}.
Boton ${B}Configure app password${N}, y despues ${B}Generate new password${N}.
Copiala: te la pido en cuanto termines este paso.
Sin ella, pihole-exporter corre pero no puede leer nada, y el tablero
   de Pi-hole en Grafana queda vacio para siempre."

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
        # Pi-hole es nativo, no un contenedor: filtrarlo por docker ps lo
        # descartaba siempre, y con el se perdia el unico camino para cargar
        # PIHOLE_API_KEY, que quedaba imposible de completar para siempre.
        if [ "$srv" = "pihole" ]; then
            command -v pihole >/dev/null 2>&1 || continue
        else
            [[ " $(servicios_elegidos "$m") " == *" $srv "* ]] || continue
            esta_arriba "$srv" || continue
        fi
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

# ── Un solo instalador a la vez ───────────────────────────────────────────────
#
# Dos corriendo en paralelo se pisan los .env, levantan los mismos contenedores
# y se contestan preguntas entre ellos. El lock es un directorio porque crearlo
# es atomico, a diferencia de comprobar y despues crear un archivo.

LOCK="/tmp/instalador-pi-services.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    duenio=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$duenio" ] && kill -0 "$duenio" 2>/dev/null; then
        falla "Ya hay otro instalador corriendo (proceso $duenio)."
        info "Esperá a que termine, o cerralo con:  kill $duenio"
        exit 1
    fi
    # El anterior murio sin limpiar
    aviso "Habia un lock viejo de un instalador que no termino. Lo saco."
    rm -rf "$LOCK" && mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"

# ── Salir a mitad de camino ───────────────────────────────────────────────────
#
# Un Ctrl-C en el momento equivocado deja un contenedor parado o un servicio a
# medio configurar. No se puede evitar, pero si decir en que se estaba.

PASO_ACTUAL=""
paso() { PASO_ACTUAL="$1"; }

al_salir() {
    local code=$?
    rm -rf "$LOCK" 2>/dev/null
    [ "$code" -eq 0 ] && return 0
    echo ""
    echo ""
    aviso "Se corto la instalacion."
    [ -n "$PASO_ACTUAL" ] && info "Iba por: ${B}$PASO_ACTUAL${N}"
    echo ""
    info "Nada de lo hecho se deshace, y no queda a medias de forma peligrosa."
    info "Volve a correrlo y sigue donde quedo: detecta lo que ya esta hecho."
    if [ ${#PENDIENTES[@]} -gt 0 ]; then
        echo ""
        info "Lo que ya quedaba anotado antes de cortar:"
        for p in "${PENDIENTES[@]}"; do gris "     · $p"; done
    fi
    echo ""
}
trap al_salir EXIT
trap 'exit 130' INT TERM

paso "revisando el equipo";        portada
info "Revisando el estado del equipo..."
detectar
# La tabla de estado se muestra UNA vez, en el menu, que ya la trae con los
# numeros al lado. Antes salia dos veces seguidas: la misma lista de doce
# filas, primero para mirar y despues para elegir.
faltantes_detallado
paso "eligiendo modulos";          menu
paso "eligiendo servicios";        elegir_servicios
paso "pidiendo los datos";         recolectar
paso "decidiendo lo del disco";    decidir_das_temprano
paso "levantando los servicios";   ejecutar
paso "aplicando las contrasenas";  recrear_por_clave
paso "configurando los servicios"; configurar_servicios
paso "guiando las cuentas";        guia_cuentas
paso ""
resumen
