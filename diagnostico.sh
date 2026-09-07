#!/bin/bash
# ==============================================================================
#  diagnostico.sh  ·  Que anda, que no, y por que
#
#      ./diagnostico.sh              todo
#      ./diagnostico.sh radarr       un servicio suelto
#      ./diagnostico.sh --breve      solo lo que esta mal
#      ./diagnostico.sh --arreglar   ofrece aplicar los arreglos al final
#      ./diagnostico.sh --avisar     ademas notifica, anota y publica metricas
#
#  Devuelve 0 si esta todo bien y 1 si hay algo mal, asi sirve para correrlo
#  desde una tarea programada.
#
#  LAS CUATRO SALIDAS
#
#  Cada hallazgo sale por cuatro lados a la vez, desde un solo punto:
#
#      pantalla   siempre, como toda la vida
#      ntfy       solo si CAMBIO de estado, y solo con --avisar
#      feed       la memoria, para mirar despues de que algo se rompa
#      metrica    a Grafana, por el textfile collector de node-exporter
#
#  --avisar lo pasa el timer pi-estado, no vos. Asi correrlo a mano nunca te
#  manda nada al celular, pero la corrida horaria si.
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
AVISAR=0
SOLO=""

for arg in "$@"; do
    case "$arg" in
        --breve|-b)     MODO_BREVE=1 ;;
        --arreglar|-a)  MODO_ARREGLAR=1 ;;
        --avisar)       AVISAR=1 ;;
        --ayuda|-h)     sed -n '3,11p' "$0" | sed 's/^# \?//'; exit 0 ;;
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
HALLAZGOS=()         # "nivel|clave", para el score del final
CONFIRMAR=0          # 1 mientras se revisan contenedores, ver mas abajo
SALUD=""             # el score, solo en corridas completas
CAPA="general"       # la seccion actual, para no repetir metricas

# ── El registro: las otras tres salidas ───────────────────────────────────────
#
# Se llama desde bien, ojo y mal, que son el unico lugar por donde pasan TODOS
# los hallazgos. Agregar un chequeo nuevo no obliga a acordarse de la metrica
# ni del aviso: salen solos.
#
# Cuidado con el orden adentro de bien(): el registro va ANTES del return
# temprano del modo breve. Ese modo es justo el que usa el timer horario, asi
# que con el registro despues del return los avisos de "se rompio" saldrian y
# los de "se resolvio" no saldrian nunca, que es la peor combinacion posible.

# Un valor de etiqueta estable y de baja cardinalidad. Nunca va aca algo que
# cambie, como el texto del hallazgo: cada valor distinto es una serie nueva
# que Prometheus guarda para siempre.
etiqueta_metrica() {
    printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '_' | sed 's/__*/_/g; s/_$//'
}

registrar() {
    local nivel="$1" clave="$2" detalle="${3:-}" codigo=0
    case "$nivel" in ojo) codigo=1 ;; mal) codigo=2 ;; esac
    HALLAZGOS+=("$nivel|$clave")
    # La capa va en la etiqueta y no es un adorno: hay servicios que se
    # revisan DOS veces y son dos preguntas distintas. Bazarr aparece en "los
    # contenedores" (¿corre y contesta?) y otra vez en "multimedia" (¿tiene
    # perfil de idiomas?). Sin la capa las dos lineas quedan identicas, y una
    # metrica repetida hace que node-exporter descarte el archivo ENTERO.
    metrica "pi_check{capa=\"${CAPA:-general}\",nombre=\"$(etiqueta_metrica "$clave")\"}" "$codigo"
    [ "$AVISAR" = "1" ] && avisar_si_cambio "$clave" "$nivel" "$clave" "$detalle" "$CONFIRMAR"
    return 0
}

bien() {
    registrar bien "$1" "${2:-}"
    [ "$MODO_BREVE" = "1" ] && return 0
    printf "  ${V}●${N} %-21s ${G}%s${N}\n" "$1" "${2:-}"
}
ojo() { registrar ojo "$1" "${2:-}"; printf "  ${A}◐${N} %-21s ${A}%s${N}\n" "$1" "${2:-}"; PROBLEMAS=$((PROBLEMAS+1)); }
mal() { registrar mal "$1" "${2:-}"; printf "  ${R}✗${N} %-21s ${R}%s${N}\n" "$1" "${2:-}"; PROBLEMAS=$((PROBLEMAS+1)); }

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
#
# Ademas deja anotada la capa para las metricas, y eso va ANTES del return del
# modo breve: si no, en la corrida horaria todos los chequeos quedarian en la
# misma capa y volverian a colisionar entre si.
seccion() {
    CAPA=$(etiqueta_metrica "$1")
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

    if [ "$usado" -ge "$DISCO_MAL" ]; then
        mal "disco" "$usado% usado, quedan $libre"
        implica "con el disco lleno las bases de datos se corrompen al escribir"
        RAIZ="el disco esta al $usado%"
        arreglo "borrar imagenes y capas que no usa nadie" "rep_liberar_docker"
    elif [ "$usado" -ge "$DISCO_OJO" ]; then
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
        metrica pi_voltaje_ok 1
        bien "voltaje" "sin bajones, ni ahora ni desde el arranque"
    else
        metrica pi_voltaje_ok 0
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
        if [ "$temp" -ge "$TEMP_OJO" ]; then
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
    metrica pi_fs_errores "${errores:-0}"
    if [ "${errores:-0}" != "0" ] && [ -n "$errores" ]; then
        # El diagnostico siempre supo que "si el contador crece es dano
        # activo", pero no podia saber si crecia: no guardaba la corrida
        # anterior. Ahora el estado de los avisos la guarda, asi que la
        # comparacion sale gratis, y es la diferencia entre "hay errores
        # viejos" y "la tarjeta se esta muriendo ahora mismo".
        if crecio fs_errores "$errores"; then
            mal "sistema de archivos" "$errores errores, y CRECIERON desde la ultima vuelta"
            implica "no es dano viejo: se esta danando ahora"
            RAIZ="el sistema de archivos se esta danando ahora"
        else
            ojo "sistema de archivos" "$errores errores registrados"
            implica "el contador no crecio, asi que es dano viejo ya contenido"
        fi
        limite "reparar el sistema de archivos" \
            "reparar ext4 pide desmontarlo, y la raiz no se desmonta en caliente" \
            "correr 'sudo touch /forcefsck && sudo reboot' cuando estes presente"
    else
        bien "sistema de archivos" "sin errores"
    fi

    # ── Que hace ext4 cuando encuentra un error ──
    #
    # De fabrica viene en "continue": sigue escribiendo sobre un sistema de
    # archivos que ya sabe que esta danado. Es el modo que convierte una
    # corrupcion chica en una tarjeta que no arranca.
    local comportamiento
    comportamiento=$(sudo dumpe2fs -h "$dev" 2>/dev/null | grep -i "^Errors behavior" | awk '{print $3}')
    if [ "$comportamiento" = "Continue" ]; then
        ojo "ante un error de disco" "sigue escribiendo"
        implica "una corrupcion chica se agranda sola en vez de frenar"
        if [ "${errores:-0}" != "0" ] && [ -n "$errores" ]; then
            limite "cambiarlo ahora" \
                "con errores sin reparar, pasarlo a solo-lectura dejaria la Pi inservible al primer tropiezo" \
                "primero el fsck, y despues: sudo tune2fs -e remount-ro $dev"
        else
            arreglo "que se proteja solo: pasar a solo-lectura ante un error" "rep_errores_remount_ro"
        fi
    elif [ -n "$comportamiento" ]; then
        bien "ante un error de disco" "se protege (${comportamiento})"
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
    #
    # Solo se reclama si el sistema arranca de una microSD, que es lo unico que
    # log2ram protege. En un disco no aporta nada y encima cuesta, porque los
    # logs recientes viven en RAM y un corte de luz se lleva justo los que
    # explicaban el corte. Avisar ahi seria reprochar una decision correcta,
    # una vez por hora, para siempre.
    local raiz_en_tarjeta=0
    case "$(findmnt -no SOURCE / 2>/dev/null)" in
        */mmcblk*) raiz_en_tarjeta=1 ;;
    esac

    if systemctl is-active log2ram >/dev/null 2>&1; then
        if mountpoint -q /var/log 2>/dev/null; then
            bien "log2ram" "activo, /var/log en RAM"
        else
            ojo "log2ram" "activo pero /var/log NO esta en RAM"
            implica "sin el montaje no sirve: los logs siguen desgastando la tarjeta"
            arreglo "reiniciarlo" "rep_reiniciar_servicio" "log2ram"
        fi
    elif [ "$raiz_en_tarjeta" = "1" ]; then
        ojo "log2ram" "apagado"
        implica "los logs escriben directo a la tarjeta y la desgastan"
        # Instalado y habilitado pero sin arrancar no es lo mismo que no
        # tenerlo, y el arreglo tampoco: uno es reiniciar, el otro instalarlo.
        systemctl is-enabled log2ram >/dev/null 2>&1 && \
            implica "esta instalado y habilitado: le falta un reinicio para arrancar"
    else
        bien "log2ram" "no hace falta, el sistema no arranca de una microSD"
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
    #
    # RestartCount es un contador DE POR VIDA que no se reinicia nunca. Y hay
    # servicios que se reinician solos como parte de su funcionamiento normal:
    # la homepage lo hace cada vez que editas su configuracion, asi que junta
    # veinticinco reinicios sin haber tenido un solo problema.
    #
    # Mirar solo ese numero era reportar como roto algo que anda perfecto y
    # lleva horas arriba. Un indicador que miente es peor que ninguno: te
    # acostumbras a ignorarlo y el dia que se rompe de verdad ya no lo mirás.
    # Con los avisos al celular es peor todavia, porque ese ruido llega al
    # bolsillo y termina con el canal silenciado.
    #
    # Un bucle de verdad son dos cosas, no una: que el contador CREZCA de una
    # corrida a la siguiente, o que el contenedor lleve segundos de vida con
    # muchos reinicios encima. Si el numero es alto pero no se movio y el
    # servicio lleva rato arriba, son cicatrices viejas y no una herida.
    local subio_reinicios=0
    crecio "reinicios_$svc" "${reinicios:-0}" && subio_reinicios=1
    edad=$(segundos_desde "$($DOCKER inspect -f '{{.State.StartedAt}}' "$svc" 2>/dev/null)")

    if [ "${reinicios:-0}" -gt 5 ] && { [ "$subio_reinicios" = "1" ] || [ "${edad:-99999}" -lt 120 ]; }; then
        mal "$svc" "reinicio $reinicios veces, y sigue reiniciandose"
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
    # Por ip_de, que es la misma que usa el instalador. Tener aca una copia
    # propia era justamente el problema: esta no sabia de la red del host y
    # daba por caido a Home Assistant, que estaba perfecto.
    local ip code
    ip=$(ip_de "$svc")
    if [ -z "$ip" ]; then
        bien "$svc" "corriendo, sin IP para consultar"
        return 0
    fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$ip:$puerto/" 2>/dev/null)
    # edad ya viene calculada del eslabon 3. Antes se volvia a pedir aca, que
    # eran veintitres docker inspect de mas por corrida.

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

    # Radarr y Sonarr se revisan igual: misma API, mismos eslabones.
    rev_un_arr radarr 7878 Radarr peliculas
    rev_un_arr sonarr 8989 Sonarr series

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

# Un *arr puede responder perfecto y no poder bajar nada. Los eslabones son
# tres y en este orden: donde guardar, con que bajar, y donde buscar.
rev_un_arr() {
    local svc="$1" puerto="$2" nombre="$3" que="$4"
    esta_arriba "$svc" || return 0

    local raices clientes idx
    raices=$(arr_api "$svc" "$puerto" v3 GET /rootfolder 2>/dev/null | grep -o '"path"' | wc -l)
    clientes=$(arr_api "$svc" "$puerto" v3 GET /downloadclient 2>/dev/null | grep -o '"protocol"' | wc -l)
    idx=$(arr_api "$svc" "$puerto" v3 GET /indexer 2>/dev/null | grep -o '"id"' | wc -l)

    if [ "${raices:-0}" -eq 0 ]; then
        ojo "$nombre" "sin carpeta raiz"
        implica "no sabe donde guardar las $que"
        arreglo "configurar $nombre" "rep_configurar_arr" "$svc"
    elif [ "${clientes:-0}" -eq 0 ]; then
        ojo "$nombre" "sin cliente de descargas"
        implica "encuentra $que pero no tiene con que bajarlas"
        arreglo "conectar qBittorrent a $nombre" "rep_configurar_arr" "$svc"
    elif [ "${idx:-0}" -eq 0 ]; then
        ojo "$nombre" "0 indexers sincronizados"
        implica "consecuencia de que Prowlarr no tenga ninguno"
    else
        bien "$nombre" "carpeta, cliente y $idx indexers"
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

}

# ══════════════════════════════════════════════════════════════════════════════
#  CAPA 6  ·  LA LINEA DE CASA
#
#  node-exporter ya mide las interfaces: cuantos bytes entran y salen. Eso no
#  contesta la pregunta que uno se hace, que es si internet anda bien.
#
#  Se mide contra una IP y no contra un nombre, a proposito: con un nombre se
#  estaria midiendo tambien al DNS, y despues no se sabe cual de los dos fallo.
# ══════════════════════════════════════════════════════════════════════════════

rev_red() {
    seccion "La linea" "· internet, no las interfaces"

    local salida perdida latencia
    salida=$(ping -q -n -c "$PING_PAQUETES" -i 0.3 -W 2 "$PING_DESTINO" 2>/dev/null)

    if [ -z "$salida" ]; then
        metrica pi_red_ok 0
        mal "internet" "sin respuesta de $PING_DESTINO"
        implica "no es la Pi: es el modem, el cable o el proveedor"
        RAIZ="no hay internet"
        limite "arreglar la conexion" \
            "esta del lado del modem o del proveedor, no de la Pi" \
            "reiniciar el modem y, si sigue, llamar al proveedor"
        return 1
    fi

    perdida=$(echo "$salida" | grep -oE '[0-9]+% packet loss' | tr -dc '0-9')
    latencia=$(echo "$salida" | awk -F'/' '/rtt|round-trip/ {printf "%d", $5}')
    [ -n "$perdida" ] || perdida=0
    [ -n "$latencia" ] || latencia=0

    metrica pi_red_ok 1
    metrica pi_red_perdida_pct "$perdida"
    metrica pi_red_latencia_ms "$latencia"

    if [ "$perdida" -ge 100 ]; then
        mal "internet" "100% de paquetes perdidos"
        implica "el enlace esta caido aunque la interfaz parezca levantada"
        RAIZ="no hay internet"
    elif [ "$perdida" -ge "$PERDIDA_OJO" ]; then
        ojo "internet" "${perdida}% de paquetes perdidos, ${latencia} ms"
        implica "asi se ve un enlace inestable: cortes cortos que no notas hasta que molestan"
    elif [ "$latencia" -ge "$LATENCIA_OJO" ]; then
        ojo "internet" "${latencia} ms de latencia"
        implica "alta para una conexion fija, mira si hay algo saturando la linea"
    else
        bien "internet" "${latencia} ms, sin perdida"
    fi

    # El historial es lo que convierte esto en algo util: un numero suelto no
    # dice nada, pero la curva de un mes muestra si el proveedor viene flojo
    # siempre a la misma hora. Esta en Grafana, fila Red.
}

# ══════════════════════════════════════════════════════════════════════════════
#  CAPA 7  ·  LOS DISCOS DEL DAS
#
#  El DAS es mergerfs sin paridad: si un disco muere, se pierde lo que habia
#  en ese disco. No hay nada que reconstruya. SMART es el UNICO aviso previo
#  que existe, y lo que compra es tiempo para copiar al otro disco.
#
#  POR QUE CADA DOS DIAS Y NO CADA HORA
#
#  Preguntarle a un disco como esta lo DESPIERTA. Un chequeo horario tendria
#  los dos discos girando las 24 horas: la herramienta que los cuida seria la
#  que los gasta. La cadencia sale de ajustes.conf.
#
#  LO QUE IMPORTA ES EL DELTA, NO EL NUMERO
#
#  Un disco con 8 sectores reasignados que hace dos anos tiene 8 esta sano.
#  Uno que paso de 0 a 8 esta semana se esta muriendo. La comparacion con la
#  corrida anterior sale gratis del archivo de estado de los avisos.
# ══════════════════════════════════════════════════════════════════════════════

# Los discos que pueden reportar salud, sin los loop de Docker ni la microSD.
#
# La microSD se excluye porque no reporta SMART: preguntarle da un error, no un
# dato. El disco del sistema SI entra cuando es un SSD o un disco duro, y eso
# esta bien aunque no sea "externo": es el que te puede dejar sin nada, y es
# justo lo que no se pudo vigilar en la Pi.
#
# El nombre y el "sin discos externos" de mas abajo quedaron de cuando el
# sistema vivia en una tarjeta y todo lo demas era, por definicion, externo.
discos_fisicos() {
    lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' | grep -vE '^(mmcblk|loop|zram)'
}

# Con que opcion lee SMART este disco. Los puentes USB no son todos iguales:
# muchos pasan con -d sat, algunos necesitan otra variante, y unos cuantos no
# lo pasan y punto. Se prueban en orden y se devuelve la primera que anda.
smart_opcion() {
    local dev="$1" f
    for f in "" "-d sat" "-d sat,12" "-d usbjmicron"; do
        # shellcheck disable=SC2086
        if sudo smartctl -H $f "$dev" 2>/dev/null | grep -qiE "self-assessment|SMART Health Status"; then
            echo "$f"; return 0
        fi
    done
    return 1
}

# Un atributo SMART por su numero de ID. La columna 10 es el valor crudo, que
# es el que sirve: las otras son valores normalizados de 0 a 100 que cada
# fabricante escala como quiere.
smart_attr() {
    echo "$2" | awk -v id="$1" '$1==id {print $10; exit}' | tr -dc '0-9'
}

rev_discos() {
    local discos; discos=$(discos_fisicos)
    # Sin discos externos no hay nada que revisar y no hay que decir nada: es
    # el estado normal mientras no exista el DAS.
    [ -n "$discos" ] || return 0

    toca_ahora discos "$CADA_CUANTO_DISCOS" "$HORA_DISCOS" || return 0

    seccion "Los discos" "· el unico aviso previo que hay, y llega con semanas"

    if ! command -v smartctl >/dev/null 2>&1; then
        ojo "SMART" "smartctl no esta instalado"
        implica "sin esto no hay forma de saber que un disco se esta muriendo"
        arreglo "instalar smartmontools" "rep_instalar_smartmontools"
        return 1
    fi

    local dev opt salud modelo reasignados pendientes nocorr crc temp horas etq
    for dev in $discos; do
        etq=$(etiqueta_metrica "$dev")
        if ! opt=$(smart_opcion "/dev/$dev"); then
            ojo "SMART $dev" "el puente USB no pasa SMART"
            implica "el disco anda, pero no vas a tener aviso previo de su muerte"
            limite "leer SMART de ese disco" \
                "lo decide el chip del gabinete, no la Pi" \
                "queda la vigilancia por errores de lectura y de ext4, que es el plan B"
            metrica_guardada "pi_smart_legible{disco=\"$etq\"}" 0
            continue
        fi
        metrica_guardada "pi_smart_legible{disco=\"$etq\"}" 1

        # shellcheck disable=SC2086
        modelo=$(sudo smartctl -i $opt "/dev/$dev" 2>/dev/null | awk -F': *' '/Device Model|Model Number|Product:/{print $2; exit}')
        # shellcheck disable=SC2086
        salud=$(sudo smartctl -H $opt "/dev/$dev" 2>/dev/null | grep -oiE "PASSED|FAILED|OK" | head -1)

        local attrs
        # shellcheck disable=SC2086
        attrs=$(sudo smartctl -A $opt "/dev/$dev" 2>/dev/null)
        reasignados=$(smart_attr 5 "$attrs");   [ -n "$reasignados" ] || reasignados=0
        pendientes=$(smart_attr 197 "$attrs");  [ -n "$pendientes" ]  || pendientes=0
        nocorr=$(smart_attr 198 "$attrs");      [ -n "$nocorr" ]      || nocorr=0
        crc=$(smart_attr 199 "$attrs");         [ -n "$crc" ]         || crc=0
        temp=$(smart_attr 194 "$attrs");        [ -n "$temp" ]        || temp=0
        horas=$(smart_attr 9 "$attrs");         [ -n "$horas" ]       || horas=0

        # Las comparaciones con la vuelta anterior se hacen SIEMPRE y antes de
        # decidir que reportar. Si fueran adentro del if, un disco que hoy
        # falla por otra cosa no actualizaria estos contadores, y manana la
        # comparacion se haria contra un valor viejo de hace semanas.
        local subio_realloc=0 subio_crc=0
        crecio "smart_realloc_$dev" "$reasignados" && subio_realloc=1
        crecio "smart_crc_$dev" "$crc" && subio_crc=1

        metrica_guardada "pi_smart_salud{disco=\"$etq\"}"          "$([ "${salud^^}" = "FAILED" ] && echo 0 || echo 1)"
        metrica_guardada "pi_smart_reasignados{disco=\"$etq\"}"    "$reasignados"
        metrica_guardada "pi_smart_pendientes{disco=\"$etq\"}"     "$pendientes"
        metrica_guardada "pi_smart_no_corregibles{disco=\"$etq\"}" "$nocorr"
        metrica_guardada "pi_smart_crc{disco=\"$etq\"}"            "$crc"
        metrica_guardada "pi_smart_temperatura{disco=\"$etq\"}"    "$temp"
        metrica_guardada "pi_smart_horas{disco=\"$etq\"}"          "$horas"

        # El orden va de lo mas grave a lo menos, y se corta en lo primero:
        # un disco que ya se declaro en falla no necesita que ademas le
        # cuentes la temperatura.
        if [ "${salud^^}" = "FAILED" ]; then
            mal "SMART $dev" "el disco se declara EN FALLA${modelo:+ ($modelo)}"
            implica "no es una prediccion, es el propio disco diciendo que ya fallo"
            limite "salvar los datos" \
                "es hardware, y no hay paridad que reconstruya nada" \
                "copiar YA lo de /mnt/$dev al otro disco, y cambiarlo"
        elif [ "$nocorr" -gt 0 ] || [ "$pendientes" -gt 0 ]; then
            mal "SMART $dev" "$pendientes pendientes, $nocorr no corregibles"
            implica "hay sectores que ya no se leen: es la senal mas temprana de muerte"
            limite "recuperar esos sectores" \
                "los decide el firmware del disco, no el sistema operativo" \
                "mira que hay en ese disco y copialo al otro mientras se pueda"
        elif [ "$reasignados" -gt 0 ] && [ "$subio_realloc" = "1" ]; then
            mal "SMART $dev" "$reasignados sectores reasignados, y crecieron"
            implica "un contador que sube es un disco degradandose ahora, no dano viejo"
        elif [ "$crc" -gt 0 ] && [ "$subio_crc" = "1" ]; then
            ojo "SMART $dev" "$crc errores CRC, y crecieron"
            implica "esto NO es el disco: es el cable o el puente USB"
            limite "descartar el cable" \
                "hay que probar con otro, y eso es fisico" \
                "cambiar el cable USB antes de sospechar del disco"
        elif [ "$temp" -ge "$DISCO_TEMP_OJO" ]; then
            ojo "SMART $dev" "${temp}°C"
            implica "sostenido, el calor acorta la vida del disco"
        else
            bien "SMART $dev" "${salud:-OK}${temp:+, ${temp}°C}${reasignados:+, $reasignados reasignados}"
        fi
    done
    evento discos "revision SMART hecha"
}

# ══════════════════════════════════════════════════════════════════════════════
#  CAPA 8  ·  EL ESPACIO Y LA BASURA
#
#  Cuanto queda lo sabe node-exporter solo, en cuanto montes el DAS. Lo que no
#  puede saber es que hay adentro que no deberia estar, y en este armado eso
#  tiene una definicion exacta:
#
#    un archivo en descargas con UN SOLO nombre es uno que nunca llego a la
#    biblioteca
#
#  Cuando Radarr importa, crea un enlace duro: el mismo archivo pasa a tener
#  dos nombres y sigue ocupando lugar una sola vez. Los que quedaron con uno
#  son importaciones fallidas, o cosas bajadas a mano y olvidadas. Espacio
#  ocupado que no le sirve a nadie, y que no aparece como error en ningun lado.
# ══════════════════════════════════════════════════════════════════════════════

rev_espacio() {
    das_montado || return 0
    toca_ahora espacio "$CADA_CUANTO_DISCOS" "$HORA_DISCOS" || return 0

    seccion "El espacio" "· cuanto queda, y que hay que no deberia estar"

    # ── Cada disco por separado ──
    #
    # mergerfs reparte solo, pero un disco al borde igual es un problema: los
    # archivos nuevos dejan de caber ahi y todo se apila en el otro.
    local punto usado
    for punto in /mnt/disk*; do
        [ -d "$punto" ] || continue
        mountpoint -q "$punto" 2>/dev/null || continue
        # El espacio en si no se escribe como metrica: node-exporter ya lo
        # publica solo para cada sistema de archivos montado. Aca se compara
        # contra el umbral, que es lo que el no puede saber.
        usado=$(df --output=pcent "$punto" 2>/dev/null | tail -1 | tr -dc '0-9')
        [ -n "$usado" ] || continue
        if [ "$usado" -ge "$DAS_MAL" ]; then
            mal "$(basename "$punto")" "$usado% usado"
            implica "sin lugar, las importaciones empiezan a fallar"
        elif [ "$usado" -ge "$DAS_OJO" ]; then
            ojo "$(basename "$punto")" "$usado% usado"
        else
            bien "$(basename "$punto")" "$usado% usado"
        fi
    done

    local das; das=$(das_ruta)

    # ── Lo que ocupa cada carpeta ──
    #
    # Recorrer la biblioteca es caro en discos que giran, por eso va aca y no
    # en cada vuelta. El numero alimenta el recuadro de la homepage y la
    # tendencia de Grafana, que es lo que de verdad sirve: no "quedan 900 GB"
    # sino "a este ritmo se llena en once semanas".
    local carpeta bytes
    for carpeta in movies tv; do
        [ -d "$das/media/$carpeta" ] || continue
        bytes=$(du -sb "$das/media/$carpeta" 2>/dev/null | awk '{print $1}')
        [ -n "$bytes" ] && metrica_guardada "pi_biblioteca_bytes{carpeta=\"$carpeta\"}" "$bytes"
    done

    # ── Los huerfanos ──
    local dir="$das/downloads/complete"
    if [ -d "$dir" ]; then
        local n bytes_h gb
        n=$(find "$dir" -type f -links 1 -mtime +"$HUERFANOS_DIAS" 2>/dev/null | wc -l | tr -d ' ')
        bytes_h=$(find "$dir" -type f -links 1 -mtime +"$HUERFANOS_DIAS" -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
        [ -n "$bytes_h" ] || bytes_h=0
        metrica_guardada pi_huerfanos_bytes "$bytes_h"
        metrica_guardada pi_huerfanos_archivos "${n:-0}"
        gb=$(( bytes_h / 1024 / 1024 / 1024 ))

        if [ "$gb" -ge "$HUERFANOS_GB" ]; then
            ojo "descargas sin importar" "$n archivos, $gb GB"
            implica "nunca llegaron a la biblioteca: es espacio ocupado al pedo"
            limite "borrarlos" \
                "borrar el archivo por atras rompe el torrent que lo comparte" \
                "sacarlos desde http://qbit.pi, que borra el archivo y limpia su estado"
        else
            bien "descargas sin importar" "$gb GB, nada para hacer"
        fi
    fi
    evento discos "revision de espacio hecha"
}

# ══════════════════════════════════════════════════════════════════════════════
#  CAPA 9  ·  LA BIBLIOTECA CONTRA EL DISCO
#
#  Radarr puede creer que tiene un archivo que en el disco ya no esta. Pasa
#  con una importacion que fallo a la mitad, con un borrado a mano, o con el
#  DAS desmontado a destiempo. No lo reporta nadie: la pelicula figura en la
#  biblioteca y al darle play no anda.
#
#  Las peliculas se revisan archivo por archivo, que es una sola llamada a la
#  API mas un stat por pelicula. Las series se revisan por carpeta y no por
#  episodio a proposito: episodio por episodio serian tantas llamadas como
#  series tengas, y el caso que importa (el DAS desmontado, una carpeta
#  borrada) se ve igual desde la carpeta.
# ══════════════════════════════════════════════════════════════════════════════

rev_biblioteca() {
    esta_arriba radarr || esta_arriba sonarr || return 0
    das_montado || return 0
    toca_ahora biblioteca "$CADA_CUANTO_BIBLIOTECA" "$HORA_BIBLIOTECA" || return 0

    seccion "La biblioteca" "· lo que dice tener contra lo que hay"

    local das; das=$(das_ruta)

    if esta_arriba radarr; then
        local salida n ejemplos
        salida=$(arr_api radarr 7878 v3 GET /movie 2>/dev/null | DAS="$das" python3 -c '
import sys, json, os
das = os.environ["DAS"]
faltan, ejemplos = 0, []
try:
    datos = json.load(sys.stdin)
except Exception:
    print(0); print(""); sys.exit(0)
for m in datos:
    if not m.get("hasFile"):
        continue
    ruta = (m.get("movieFile") or {}).get("path")
    if not ruta:
        continue
    if not os.path.exists(ruta.replace("/data", das, 1)):
        faltan += 1
        if len(ejemplos) < 2:
            ejemplos.append(m.get("title", "?"))
print(faltan)
print(", ".join(ejemplos))
' 2>/dev/null)
        n=$(echo "$salida" | head -1 | tr -dc '0-9')
        ejemplos=$(echo "$salida" | tail -1)
        [ -n "$n" ] || n=0
        metrica_guardada pi_biblioteca_faltantes "$n"
        if [ "$n" -gt 0 ]; then
            ojo "peliculas" "$n figuran y no estan en disco"
            implica "aparecen en Jellyfin y al darles play no andan"
            [ -n "$ejemplos" ] && probe "por ejemplo: $ejemplos"
            limite "recuperarlas" \
                "el archivo no esta, no hay nada que arreglar por software" \
                "en Radarr, Movies, seleccionarlas y darles Search para volver a bajarlas"
        else
            bien "peliculas" "todas las que figuran estan"
        fi
    fi

    if esta_arriba sonarr; then
        local salida n
        salida=$(arr_api sonarr 8989 v3 GET /series 2>/dev/null | DAS="$das" python3 -c '
import sys, json, os
das = os.environ["DAS"]
faltan = 0
try:
    datos = json.load(sys.stdin)
except Exception:
    print(0); sys.exit(0)
for s in datos:
    ruta = s.get("path")
    stats = s.get("statistics") or {}
    if not ruta or not stats.get("episodeFileCount"):
        continue
    if not os.path.isdir(ruta.replace("/data", das, 1)):
        faltan += 1
print(faltan)
' 2>/dev/null)
        n=$(echo "$salida" | head -1 | tr -dc '0-9')
        [ -n "$n" ] || n=0
        metrica_guardada pi_series_sin_carpeta "$n"
        if [ "$n" -gt 0 ]; then
            ojo "series" "$n con episodios y sin carpeta en disco"
            implica "o se borro la carpeta, o el DAS no estaba montado al importar"
        else
            bien "series" "todas las carpetas estan"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  CAPA 10  ·  EL QUE AVISA
#
#  Lo mas facil de que se rompa en silencio es justamente el que tiene que
#  avisar cuando algo se rompe. Si el canal no esta configurado o el gancho de
#  Radarr se perdio en una recreacion, no hay ningun sintoma: simplemente deja
#  de llegar lo que nunca ibas a extranar hasta que lo necesites.
# ══════════════════════════════════════════════════════════════════════════════

rev_avisos() {
    seccion "Los avisos" "· el que avisa tambien puede romperse"

    if avisos_apagados; then
        # Dijiste que no los queres. Eso es un estado valido, no una falta, y
        # un diagnostico que te reprocha una decision tuya en cada corrida es
        # ruido que despues se ignora entero.
        bien "canales" "apagados a proposito"
        metrica pi_avisos_ok 1
    elif ! avisos_configurados; then
        ojo "canales" "sin configurar"
        implica "el diagnostico ve todo y no te lo puede decir a ningun lado"
        limite "crearlos" \
            "hay que elegir los nombres y suscribirse desde tu celular" \
            "correr ./instalador.sh y elegir el modulo Avisos"
        metrica pi_avisos_ok 0
    elif ! command -v curl >/dev/null 2>&1; then
        mal "canales" "falta curl"
        implica "los avisos no salen, y no hay forma de que te enteres de que no salen"
        metrica pi_avisos_ok 0
    else
        bien "canales" "configurados"
        metrica pi_avisos_ok 1
    fi

    # El feed: que exista y que no se haya desbordado.
    if [ -s "$FEED" ]; then
        local lineas
        lineas=$(wc -l < "$FEED" | tr -d ' ')
        metrica pi_feed_lineas "$lineas"
        if [ "$lineas" -gt $(( FEED_LINEAS * 3 )) ]; then
            ojo "feed" "$lineas lineas, deberia cortarse en $FEED_LINEAS"
            implica "algo esta escribiendo mas rapido de lo que se recorta"
        else
            bien "feed" "$lineas eventos, en http://eventos.pi"
        fi
    else
        metrica pi_feed_lineas 0
        bien "feed" "vacio todavia"
    fi

    # Los ganchos de media: se pierden en silencio si alguien recrea el
    # contenedor con una configuracion vieja. Sin avisos no hay gancho que
    # revisar, asi que no se dice nada.
    avisos_configurados || return 0
    local svc puerto faltan=()
    for svc in radarr:7878 sonarr:8989; do
        puerto="${svc#*:}"; svc="${svc%%:*}"
        esta_arriba "$svc" || continue
        if ! arr_api "$svc" "$puerto" v3 GET /notification 2>/dev/null | grep -q "avisar-import"; then
            faltan+=("$svc")
        fi
    done
    if [ ${#faltan[@]} -gt 0 ]; then
        ojo "gancho de media" "sin configurar en ${faltan[*]}"
        implica "las importaciones no te van a llegar al celular"
        arreglo "volver a engancharlo" "rep_ganchos_media"
    elif esta_arriba radarr || esta_arriba sonarr; then
        bien "gancho de media" "puesto"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  EL SCORE
#
#  Un solo numero que dice si hace falta abrir algo. Verde significa no abras
#  nada, y esa es toda su funcion.
#
#  NO ES UN PROMEDIO DE CATEGORIAS, y eso es lo unico que importa del diseno.
#  Con un promedio de cinco categorias, un disco muriendose te muestra 96 y no
#  lo miras. Aca se arranca en 100 y se resta lo que cuesta cada cosa, asi que
#  UN SOLO problema de los graves te deja en 60, o sea en rojo, sin que haga
#  falta que se acumule nada mas.
#
#  Y al reves: diez configuraciones flojas te dejan en 70, incomodo pero no
#  urgente. Que es exactamente lo correcto.
#
#  LO QUE NO HACE
#
#  El score solo ve lo que esta chequeado. En marzo, cuando logrotate se
#  murio, este numero habria marcado 100 durante cinco meses porque nadie le
#  preguntaba a logrotate. La leccion no es "pone un score", es "cada vez que
#  algo te sorprenda, agrega el chequeo".
# ══════════════════════════════════════════════════════════════════════════════

clase_de() {
    case "$1" in
        voltaje|disco|"sistema de archivos"|"el disco"|respaldo|SMART*|disk*) echo datos ;;
        Pi-hole|Caddy|jellyfin|homepage|internet)                             echo caido ;;
        log2ram|"chequeo del disco"|"ante un error de disco"|firewall|Tailscale|canales|feed|"gancho de media") echo config ;;
        *)                                                                     echo degradado ;;
    esac
}

calcular_salud() {
    local puntos=100 linea nivel clave castigo
    [ ${#HALLAZGOS[@]} -eq 0 ] && { echo "$puntos"; return; }
    for linea in "${HALLAZGOS[@]}"; do
        nivel="${linea%%|*}"; clave="${linea#*|}"
        [ "$nivel" = "bien" ] && continue
        case "$(clase_de "$clave")" in
            datos)      [ "$nivel" = "mal" ] && castigo=40 || castigo=10 ;;
            caido)      [ "$nivel" = "mal" ] && castigo=15 || castigo=5 ;;
            config)     castigo=3 ;;
            *)          [ "$nivel" = "mal" ] && castigo=8 || castigo=4 ;;
        esac
        puntos=$(( puntos - castigo ))
    done
    [ "$puntos" -lt 0 ] && puntos=0
    echo "$puntos"
}

# El score y el conteo, en un JSON que sirve el mismo Caddy para el recuadro
# de la homepage. Un archivo estatico y ningun servicio nuevo.
publicar_estado() {
    local salud="$1" tmp="$DATOS/estado.json.tmp"
    mkdir -p "$DATOS" 2>/dev/null || return 0
    printf '{"salud":%s,"problemas":%s,"actualizado":"%s"}\n' \
        "$salud" "$PROBLEMAS" "$(date '+%Y-%m-%d %H:%M')" > "$tmp" 2>/dev/null \
        && mv "$tmp" "$DATOS/estado.json"
    return 0
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

rep_instalar_smartmontools() {
    sudo apt-get install -y smartmontools >/dev/null 2>&1
    command -v smartctl >/dev/null 2>&1
}

# El gancho de las importaciones vive en la configuracion de Radarr y Sonarr,
# que se pierde si alguien recrea el contenedor desde cero. Como el instalador
# ya sabe ponerlo, aca se reusa esa misma funcion en vez de escribirlo dos veces.
rep_ganchos_media() {
    cfg_ganchos_media >/dev/null 2>&1
    local svc puerto
    for svc in radarr:7878 sonarr:8989; do
        puerto="${svc#*:}"; svc="${svc%%:*}"
        esta_arriba "$svc" || continue
        arr_api "$svc" "$puerto" v3 GET /notification 2>/dev/null | grep -q "avisar-import" || return 1
    done
    return 0
}

# Que ext4 se remonte de solo lectura ante un error en vez de seguir
# escribiendo. Se guarda en el superbloque, asi que aplica tambien al montaje
# que hace el initramfs, antes de que se lean las opciones de fstab.
rep_errores_remount_ro() {
    sudo tune2fs -e remount-ro "$(findmnt -no SOURCE /)" >/dev/null 2>&1
    [ "$(sudo dumpe2fs -h "$(findmnt -no SOURCE /)" 2>/dev/null | grep -i "^Errors behavior" | awk "{print \}")" = "Remount" ]
}

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

rep_configurar_arr() {
    pedir_clave_maestra
    case "$1" in
        radarr) cfg_radarr "$CLAVE_MAESTRA" ;;
        sonarr) cfg_sonarr "$CLAVE_MAESTRA" ;;
        *)      return 1 ;;
    esac
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
        ok "No encontre nada roto.${SALUD:+  Salud: ${B}$SALUD${N}/100}"
        return 0
    fi

    titulo "En resumen"
    if [ -n "$SALUD" ]; then
        local color="$V"
        [ "$SALUD" -lt 90 ] && color="$A"
        [ "$SALUD" -lt 70 ] && color="$R"
        echo "  Salud  ${color}${B}$SALUD${N}${G}/100${N}   ·   ${B}$PROBLEMAS${N} $(plural "$PROBLEMAS" "cosa" "cosas") para mirar."
    else
        echo "  ${B}$PROBLEMAS${N} cosas para mirar."
    fi
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
    rev_red
    rev_dns
    rev_caddy

    seccion "Los contenedores" "· que existan, corran y contesten"
    # Un contenedor que se reinicia treinta segundos durante una actualizacion
    # no puede despertarte a las 3 de la manana. Mientras dura este bucle, los
    # avisos esperan a la corrida siguiente para confirmar que el problema
    # sigue ahi. Dos falsas alarmas alcanzan para que silencies el canal.
    CONFIRMAR=1
    for s in $($DOCKER ps -a --format '{{.Names}}' 2>/dev/null | sort); do
        [ "$s" = "caddy" ] && continue
        revisar_contenedor "$s"
    done
    CONFIRMAR=0

    rev_media
    rev_monitoreo
    rev_tokens
    rev_nativos
    rev_discos
    rev_espacio
    rev_biblioteca
    rev_avisos
fi

aplicar_arreglos

# ── Las otras tres salidas ────────────────────────────────────────────────────
#
# Solo en las corridas completas. Una corrida de un servicio suelto
# (./diagnostico.sh radarr) mira un contenedor y nada mas: si escribiera el
# archivo de metricas, borraria las otras 39, porque se reescribe entero.
if [ -z "$SOLO" ]; then
    SALUD=$(calcular_salud)
    metrica pi_salud "$SALUD"
    metrica pi_problemas "$PROBLEMAS"
    metricas_volcar
    metricas_guardadas_volcar
    metricas_guardadas_publicar
    publicar_estado "$SALUD"
fi

resumen_final
[ "$PROBLEMAS" -eq 0 ]
