#!/bin/bash
# ==============================================================================
#  lib/torrents.sh  ·  qBittorrent: aislarlo, y decidir si se abre su puerto
#
#  No se ejecuta solo: se carga con source desde comun.sh.
#
#  qBittorrent es el unico contenedor del stack que habla con desconocidos de
#  internet, y el unico que, con el puerto abierto, recibe conexiones que no
#  pidio. Si alguien encontrara una falla en el, lo que importa es hasta donde
#  llegaria despues. Este archivo se ocupa de dos cosas:
#
#  1. LIMITAR EL DANO, se abra o no el puerto
#     · una red de Docker aparte, compartida solo con quienes le hablan;
#     · una regla del firewall que le impide llegar a SSH, Home Assistant y
#       Pi-hole de esta maquina (los permisos del contenedor van en el compose).
#
#  2. DECIDIR SI SE ABRE EL PUERTO, y que la persona sepa que implica
#     Por defecto queda cerrado. Abrirlo ayuda sobre todo a los demas, y tiene
#     un costo de seguridad que no es cero, asi que se pregunta y se explica en
#     vez de decidirlo por vos.
#
#  El estado vive en media/.env:
#      QBIT_ESCUCHA   127.0.0.1 = cerrado · 0.0.0.0 = abierto
#      QBIT_UPNP      1 = el router lo abre solo, via UPnP · 0 = a mano
#  y el compose lo lee para publicar el puerto en una direccion u otra.
# ==============================================================================

RED_TORRENT="pi-torrent"

# Los contenedores que le hablan a qBittorrent. Estan en su red ademas de la de
# siempre, y son los unicos que lo ven: Radarr y Sonarr le mandan las descargas,
# Caddy le sirve la web (qbit.pi) y la homepage muestra su estado.
TORRENT_VECINOS="radarr sonarr caddy homepage"

# ── Que estado hay hoy ────────────────────────────────────────────────────────

torrent_puerto() {
    local p; p=$(leer_var media/.env QBIT_TORRENT_PORT 2>/dev/null)
    echo "${p:-6881}"
}

# 127.0.0.1 = cerrado (ni la red local lo alcanza) · 0.0.0.0 = abierto
torrent_escucha() {
    local e; e=$(leer_var media/.env QBIT_ESCUCHA 2>/dev/null)
    echo "${e:-127.0.0.1}"
}

torrent_abierto()       { [ "$(torrent_escucha)" = "0.0.0.0" ]; }
torrent_upnp_elegido()  { [ "$(leer_var media/.env QBIT_UPNP 2>/dev/null)" = "1" ]; }

# La primera subred IPv4 de la red de torrents. Docker puede asignarle tambien
# una IPv6, y la regla del firewall tiene que llevar la IPv4.
torrent_subred() {
    $DOCKER network inspect "$RED_TORRENT" \
        --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
        | tr ' ' '\n' | awk '/\./ && !/:/ {print; exit}'
}

torrent_gateway() {
    $DOCKER network inspect "$RED_TORRENT" \
        --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null \
        | tr ' ' '\n' | awk '/\./ && !/:/ {print; exit}'
}

# ── Las redes de Docker ───────────────────────────────────────────────────────

# La red tiene que existir ANTES de levantar. Nueve composes declaran la de
# siempre como externa porque estan pensados para poder correr sueltos, y los
# que le hablan a qBittorrent declaran tambien la de torrents: si alguna falta,
# el up construye todo durante una hora y recien al final falla sin levantar
# nada.
#
# Se llama en cada modulo y no una sola vez al principio: asi da igual que
# levantes dos modulos hoy y tres el mes que viene. Y se crean las DOS siempre,
# aunque no instales multimedia, porque Caddy y la homepage ya las nombran.
asegurar_redes_docker() {
    local red existentes
    for red in pi-services "$RED_TORRENT"; do
        existentes=$($DOCKER network ls --format '{{.Name}}' 2>/dev/null)
        echo "$existentes" | grep -qx "$red" && continue
        $DOCKER network create "$red" >/dev/null 2>&1
        existentes=$($DOCKER network ls --format '{{.Name}}' 2>/dev/null)
        if echo "$existentes" | grep -qx "$red"; then
            ok "Red '$red' creada"
        else
            # Sin esta red no se levanta nada, asi que conviene enterarse aca y
            # no en el primer contenedor que no arranca por un motivo que no
            # menciona la red.
            falla "No pude crear la red '$red'"
            gris "     sin ella los contenedores no se ven entre si ni los alcanza Caddy"
            return 1
        fi
    done
    return 0
}

# ── Que no llegue al resto de esta maquina ────────────────────────────────────
#
#  Estar en otra red de Docker evita que qBittorrent vea a los otros
#  contenedores, pero NO evita que alcance los servicios del equipo en si: para
#  el, esta maquina es la puerta de enlace, y los puertos que ella escucha
#  (SSH, Home Assistant, el panel de Pi-hole) le quedan al alcance. Medido en la
#  instalacion real antes de esta regla: llegaba a SSH, 8123 y 8181.
#
#  El firewall ya permitia a los rangos 172.17 a 172.20 hablar con Home
#  Assistant y Pi-hole, y la red de torrents cae justo en uno de ellos. Por eso
#  la regla de bloqueo va PRIMERA: UFW toma la primera que coincide.
#
#  Lo que no se cierra con esto: los puertos que Docker publica (Caddy, Jellyfin,
#  Seerr). Entran por otro camino que UFW no filtra, y son los mismos que ve
#  cualquier aparato de la red local. Todos piden login.
torrent_aislar_host() {
    local sub reglas viejas n
    sub=$(torrent_subred)
    [ -n "$sub" ] || { aviso "No encuentro la red de torrents"; return 1; }

    if ! command -v ufw >/dev/null 2>&1 || ! sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        aviso "El firewall (UFW) no esta activo"
        gris "     sin el, qBittorrent alcanza SSH y los paneles de este equipo"
        pendiente "Activar el firewall para aislar qBittorrent:  pi seguridad"
        return 1
    fi

    reglas=$(sudo ufw status numbered 2>/dev/null)

    # Si la red se recreo y cambio de subred, la regla de antes quedo apuntando
    # a un rango que ya no es el suyo. Se saca, de atras para adelante para que
    # los numeros no se corran.
    viejas=$(echo "$reglas" | grep "pi-torrent:" | grep -vF "$sub" \
             | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn)
    for n in $viejas; do sudo ufw --force delete "$n" >/dev/null 2>&1; done
    [ -n "$viejas" ] && reglas=$(sudo ufw status numbered 2>/dev/null)

    if echo "$reglas" | grep "pi-torrent:" | grep -qF "$sub"; then
        gris "     la regla del firewall para $sub ya estaba"
        return 0
    fi

    sudo ufw insert 1 deny from "$sub" to any \
        comment "pi-torrent: qBittorrent sin acceso a este equipo" >/dev/null 2>&1

    # Se relee: que el comando no falle no dice que la regla haya quedado
    reglas=$(sudo ufw status numbered 2>/dev/null)
    if echo "$reglas" | grep "pi-torrent:" | grep -qF "$sub"; then
        ok "Firewall: qBittorrent ya no alcanza SSH ni los paneles de este equipo"
        return 0
    fi
    aviso "No pude agregar la regla del firewall para $sub"
    pendiente "Aislar qBittorrent del equipo:  sudo ufw insert 1 deny from $sub to any"
    return 1
}

# La prueba de verdad: desde adentro de qBittorrent, intentar llegar al SSH de
# esta maquina. Si responde, la regla no esta haciendo su trabajo aunque figure.
torrent_comprobar_aislamiento() {
    esta_arriba qbittorrent || return 0
    local gw; gw=$(torrent_gateway)
    [ -n "$gw" ] || return 0
    # Sin nc en la imagen no hay forma de probarlo: se calla en vez de dar un
    # "aislado" que no se midio.
    $DOCKER exec qbittorrent sh -c 'command -v nc >/dev/null' 2>/dev/null || return 0
    if $DOCKER exec qbittorrent sh -c "nc -z -w 3 $gw 22" >/dev/null 2>&1; then
        aviso "qBittorrent todavia alcanza el SSH de este equipo"
        return 1
    fi
    return 0
}

# ── Aplicar el refuerzo a lo que ya esta corriendo ────────────────────────────
#
#  En una instalacion nueva los contenedores nacen ya con la red aparte y los
#  permisos recortados, porque estan en el compose. Pero en una que existia
#  antes, el instalador no toca lo que ya esta arriba: hay que recrearlos.
#
#  `up -d` solo recrea los que cambiaron, asi que es seguro correrlo siempre. Y
#  se limita a los que YA estan corriendo: nombrar un servicio en `up` lo
#  levanta, y no corresponde prender Caddy o la homepage si no los instalaste.
torrent_aplicar_refuerzo() {
    esta_arriba qbittorrent || return 0
    local s lista="qbittorrent" salida

    for s in $TORRENT_VECINOS; do
        esta_arriba "$s" && lista="$lista $s"
    done

    # shellcheck disable=SC2086
    salida=$($DOCKER compose up -d $lista 2>&1)
    if echo "$salida" | grep -q "Recreate"; then
        ok "qBittorrent en su propia red y con los permisos recortados"
        gris "     se recrearon: $(echo "$salida" | grep -E "Recreated" | awk '{print $2}' | sort -u | tr '\n' ' ')"
        esperar_http qbittorrent 8080 / >/dev/null 2>&1
    else
        gris "     qBittorrent ya tenia su red y sus permisos"
    fi
}

# ── Abrir o cerrar el puerto en el router ─────────────────────────────────────
#
#  Publicar el puerto en esta maquina no alcanza para que llegue gente de
#  internet: tambien hay que reenviarlo en el router. Hay dos formas, y ninguna
#  toca el router a mano si elegis UPnP.

# IPs privadas y de CGNAT: si el router recibe una de estas como IP "publica",
# el proveedor comparte una sola entre muchos clientes y NINGUN reenvio de
# puertos sirve, ni a mano ni por UPnP.
_ip_es_compartida() {
    case "$1" in
        10.*|192.168.*|169.254.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
    esac
    return 1
}

torrent_upnp_instalar() {
    command -v upnpc >/dev/null 2>&1 && return 0
    info "Instalando miniupnpc, el programa que habla UPnP con el router..."
    sudo apt-get install -y miniupnpc >/dev/null 2>&1
    command -v upnpc >/dev/null 2>&1
}

# Le pregunta al router, sin cambiarle nada: si responde por UPnP, cual es su IP
# publica y cual es la de esta maquina. Deja el resultado en variables.
UPNP_LAN=""; UPNP_WAN=""
torrent_upnp_sondear() {
    local salida
    UPNP_LAN=""; UPNP_WAN=""
    torrent_upnp_instalar || return 1
    salida=$(timeout 15 upnpc -s 2>&1)
    echo "$salida" | grep -q "Found valid IGD" || return 1
    UPNP_LAN=$(echo "$salida" | grep -oE "Local LAN ip address : [0-9.]+" | awk '{print $NF}')
    UPNP_WAN=$(echo "$salida" | grep -oE "ExternalIPAddress = [0-9.]+" | awk '{print $NF}')
    [ -n "$UPNP_LAN" ]
}

# Pide el reenvio, para TCP y UDP, con una vigencia de una hora. La tarea
# programada pi-upnp lo renueva cada media: si la mini PC se apaga, el permiso
# vence solo y el router queda como estaba, en vez de quedar abierto para
# siempre apuntando a nada.
torrent_upnp_abrir() {
    local p lan salida proto
    p=$(torrent_puerto)
    torrent_upnp_sondear || return 1
    lan="$UPNP_LAN"
    for proto in TCP UDP; do
        salida=$(timeout 20 upnpc -e "Pi-Services qBittorrent" -a "$lan" "$p" "$p" "$proto" 3600 2>&1)
        echo "$salida" | grep -qiE "is redirected to internal|success|code 200|^ok" || return 1
    done
    return 0
}

# Se saca el permiso. Sin salida: se llama tambien cuando nunca hubo ninguno.
torrent_upnp_cerrar() {
    command -v upnpc >/dev/null 2>&1 || return 0
    local p proto; p=$(torrent_puerto)
    for proto in TCP UDP; do
        timeout 15 upnpc -d "$p" "$proto" >/dev/null 2>&1
    done
    return 0
}

# La renovacion silenciosa que corre el timer. No pregunta ni imprime nada
# salvo si algo falla, y ahi sale con error para que systemd lo deje a la vista.
torrent_upnp_renovar() {
    torrent_abierto && torrent_upnp_elegido || return 0
    torrent_upnp_abrir
}

# Lo unico que prueba de verdad que alguien de afuera puede llegar: pedirle a un
# servicio externo que intente conectarse a tu IP publica. Manda tu IP y el
# puerto a ifconfig.co, pero eso ya lo ve cualquiera con quien compartas un
# torrent. Solo prueba TCP.
#
# Tres respuestas y no dos, porque "no se ve" y "no pude preguntar" no son lo
# mismo: sin internet, o con el servicio caido, decir que el puerto esta
# cerrado seria una falsa alarma cada vez.
#   0 = se ve   ·   1 = NO se ve   ·   2 = no hubo respuesta
torrent_probar_afuera() {
    local p r; p=$(torrent_puerto)
    r=$(curl -s -m "${1:-15}" "https://ifconfig.co/port/$p" 2>/dev/null)
    echo "$r" | grep -qE '"reachable": ?true'  && return 0
    echo "$r" | grep -qE '"reachable": ?false' && return 1
    return 2
}

# ── El asistente: la pregunta, y todo lo que hace falta para decidir ──────────

_explicar_puerto() {
    local p estado
    p=$(torrent_puerto)
    if torrent_abierto; then
        estado="${A}ABIERTO${N}  ${G}(esta maquina lo publica$(torrent_upnp_elegido && echo ", y el router lo abre por UPnP"))${N}"
    else
        estado="${V}CERRADO${N}  ${G}(solo esta maquina puede conectarse)${N}"
    fi

    echo ""
    echo "  ${B}${C}El puerto de torrents ($p)${N}"
    echo ""
    echo "  Hoy esta: $estado"
    echo ""
    info "qBittorrent baja y sube datos conectandose con otras personas. Las"
    info "conexiones que ${B}vos inicias${N} funcionan siempre, con el puerto como este."
    info "Abrirlo permite que ${B}otros te inicien${N} conexiones a vos."
    echo ""
    echo "  ${B}Que ganas abriendolo${N}"
    info "· Podes sembrar de verdad. Hoy casi nadie puede alcanzarte, asi que no subis nada."
    info "· Llegas a torrents con muy pocos seeds, si ellos tambien estan detras de un router."
    gris "     No cambia la velocidad de los torrents populares ni ahorra espacio, y el"
    gris "     ratio solo importa en trackers privados. Ayuda sobre todo a los demas."
    echo ""
    echo "  ${B}Que implica${N}"
    info "· Un programa queda expuesto a internet: qBittorrent. Una falla suya seria la"
    info "  puerta de entrada, y el firewall de esta maquina no filtra este puerto."
    info "· Tu IP no queda mas expuesta: el enjambre ya la ve cuando descargas."
    echo ""
    echo "  ${B}Lo que ya queda hecho para limitar el dano, lo abras o no${N}"
    info "· qBittorrent vive en su propia red de Docker: no ve a los otros contenedores."
    info "· Sin permisos de root ni forma de ganar mas: solo cinco permisos minimos."
    info "· El firewall le impide llegar a SSH, Home Assistant y Pi-hole de esta maquina."
    gris "     No cubre los puertos que ya publica Docker (Caddy, Jellyfin, Seerr), que son"
    gris "     los mismos que ve cualquier aparato de tu red local, ni a esos aparatos."
    echo ""
}

# Cuenta que hacer en el router si se eligio hacerlo a mano
_instrucciones_router() {
    local p; p=$(torrent_puerto)
    echo ""
    info "En el router, reenvia este puerto (${B}port forwarding${N}):"
    gris "        puerto externo     $p   (TCP y UDP)"
    gris "        puerto interno     $p"
    gris "        destino            $IP_FIJA   (esta maquina)"
    info "Y conviene una ${B}reserva de IP${N} para esta maquina, asi el destino no cambia."
    info "Cuando lo hagas:  ${B}pi puerto${N}  comprueba si se ve desde afuera."
    echo ""
}

# Pregunta y deja la eleccion en media/.env. NO levanta ni cambia nada mas: eso
# lo hace torrent_proteger despues de que los contenedores esten arriba.
torrent_asistente() {
    local actual defecto r
    _explicar_puerto

    if torrent_abierto && torrent_upnp_elegido; then actual=2
    elif torrent_abierto; then actual=3
    else actual=1; fi
    defecto="$actual"

    echo "     ${B}1${N})  Dejarlo ${B}cerrado${N}   ${G}(recomendado)${N}"
    gris "         Descargas igual. Casi no sembras."
    echo "     ${B}2${N})  Abrirlo, y que la mini PC lo pida al router por ${B}UPnP${N}"
    gris "         No tocas el router. Cualquier aparato de tu red puede pedirle lo mismo al"
    gris "         router, no solo esta maquina. El permiso se renueva solo cada media hora."
    echo "     ${B}3${N})  Abrirlo, y lo reenvio ${B}yo${N} en el router"
    gris "         Mas control: la regla la creas vos y no se renueva sola."
    echo ""

    read -r -p "     ${B}Que hago${N} [1/2/3, Enter = $defecto]: " r </dev/tty 2>/dev/null || r=""
    r="${r:-$defecto}"

    case "$r" in
        2)
            info "Consultando al router, sin cambiarle nada..."
            if ! torrent_upnp_sondear; then
                aviso "El router no responde por UPnP (o no se pudo instalar miniupnpc)"
                info "Lo dejo para reenviar a mano: necesita que lo hagas vos en el router."
                escribir_var media/.env QBIT_UPNP 0
                escribir_var media/.env QBIT_ESCUCHA 0.0.0.0
                _instrucciones_router
                pendiente "Reenviar el puerto $(torrent_puerto) en el router hacia $IP_FIJA (ver pi puerto)"
                return 0
            fi
            if [ -n "$UPNP_WAN" ] && _ip_es_compartida "$UPNP_WAN"; then
                aviso "Tu router recibe la IP $UPNP_WAN, que es privada o compartida"
                info "Tu proveedor comparte una sola IP publica entre muchos clientes. Ningun"
                info "reenvio de puertos sirve asi, ni a mano ni por UPnP. Lo dejo cerrado."
                escribir_var media/.env QBIT_ESCUCHA 127.0.0.1
                escribir_var media/.env QBIT_UPNP 0
                return 0
            fi
            ok "El router responde por UPnP${UPNP_WAN:+  ·  IP publica: $UPNP_WAN}"
            escribir_var media/.env QBIT_ESCUCHA 0.0.0.0
            escribir_var media/.env QBIT_UPNP 1
            ;;
        3)
            escribir_var media/.env QBIT_ESCUCHA 0.0.0.0
            escribir_var media/.env QBIT_UPNP 0
            _instrucciones_router
            pendiente "Reenviar el puerto $(torrent_puerto) en el router hacia $IP_FIJA (ver pi puerto)"
            ;;
        *)
            escribir_var media/.env QBIT_ESCUCHA 127.0.0.1
            escribir_var media/.env QBIT_UPNP 0
            ok "Queda cerrado"
            ;;
    esac
    # Para no volver a explicar todo en cada corrida del instalador
    escribir_var media/.env QBIT_PUERTO_DECIDIDO 1
    return 0
}

# ── Aplicar todo, con los contenedores ya arriba ──────────────────────────────

torrent_proteger() {
    esta_arriba qbittorrent || return 0
    local rc

    torrent_aislar_host
    torrent_aplicar_refuerzo
    torrent_comprobar_aislamiento || true

    if torrent_abierto; then
        if torrent_upnp_elegido; then
            if torrent_upnp_abrir; then
                ok "Puerto $(torrent_puerto) pedido al router por UPnP"
                # El router tarda un instante en aplicar la regla
                sleep 3
            else
                aviso "El router no acepto el pedido de UPnP"
                pendiente "Reenviar el puerto $(torrent_puerto) en el router hacia $IP_FIJA, o dejarlo cerrado:  pi puerto"
                return 0
            fi
        fi
        torrent_probar_afuera; rc=$?
        if [ "$rc" = "0" ]; then
            ok "El puerto $(torrent_puerto) se ve desde internet"
        elif [ "$rc" = "1" ]; then
            aviso "El puerto $(torrent_puerto) todavia no se ve desde internet"
            gris "     Si ya lo reenviaste, puede tardar. Para volver a probar:  pi puerto"
            torrent_upnp_elegido || pendiente "Confirmar que el reenvio del puerto $(torrent_puerto) funciona:  pi puerto"
        else
            gris "     No pude comprobar desde afuera si el puerto se ve (sin respuesta del servicio de prueba)"
        fi
    else
        torrent_upnp_cerrar
        ok "Puerto de torrents cerrado: solo esta maquina puede conectarse"
    fi
    return 0
}

# ── pi puerto ─────────────────────────────────────────────────────────────────
#
#  Para ver como esta y cambiarlo despues, sin volver a correr todo el
#  instalador.
torrent_comando() {
    local sub p rc
    p=$(torrent_puerto)
    echo ""
    echo "  ${B}${C}Puerto de torrents${N}  ${G}($p)${N}"
    echo ""

    if ! esta_arriba qbittorrent; then
        aviso "qBittorrent no esta corriendo"
        info "Instala multimedia primero:  ${B}pi instalar${N}"
        echo ""
        return 1
    fi

    if torrent_abierto; then
        info "Esta maquina:   ${A}publica${N} el puerto"
        torrent_upnp_elegido && info "Router:         ${A}por UPnP${N}, se renueva cada media hora" \
                             || info "Router:         ${A}reenvio a mano${N}"
        torrent_probar_afuera; rc=$?
        if [ "$rc" = "0" ]; then
            ok "Desde internet: ${B}se ve${N}. Otros pueden conectarse a vos."
        elif [ "$rc" = "1" ]; then
            aviso "Desde internet: ${B}no se ve${N}"
            gris "     Falta el reenvio en el router, o tu proveedor comparte la IP."
        else
            aviso "Desde internet: no pude comprobarlo (el servicio de prueba no contesto)"
        fi
    else
        info "Esta maquina:   ${V}cerrado${N}: ni la red local lo alcanza"
        ok "Desde internet: no se ve (es lo esperado)"
    fi

    echo ""
    info "Aislamiento de qBittorrent:"
    local redes sec sub
    redes=$($DOCKER inspect qbittorrent --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null)
    sec=$($DOCKER inspect qbittorrent --format '{{.HostConfig.SecurityOpt}}' 2>/dev/null)
    [ "${redes% }" = "$RED_TORRENT" ] && ok "red aparte ($RED_TORRENT)" || aviso "no esta aislado en su red: $redes"
    [[ "$sec" == *no-new-privileges* ]] && ok "sin forma de ganar privilegios" || aviso "puede ganar privilegios"
    sub=$(torrent_subred)
    if sudo ufw status 2>/dev/null | grep "pi-torrent:" | grep -qF "${sub:-sin-subred}"; then
        ok "el firewall le bloquea el acceso a esta maquina"
    else
        aviso "sin la regla del firewall: alcanza SSH y los paneles de esta maquina"
    fi
    echo ""

    preguntar "¿Queres cambiar si el puerto esta abierto o cerrado?" "n" || { echo ""; return 0; }
    torrent_asistente
    torrent_proteger
    echo ""
}
