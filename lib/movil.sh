# ==============================================================================
#  LAS APPS DEL CELULAR
#
#  Todo lo que corre en esta maquina se usa desde el navegador, y eso alcanza
#  para probar pero no para el dia a dia: nadie abre un navegador, escribe una
#  direccion y busca la contrasena para apagar el bloqueo de publicidad dos
#  minutos. Con una app en la pantalla de inicio, si.
#
#  El problema nunca fue instalar la app, es que cada una pide una direccion y
#  una clave distinta, guardadas en cinco lugares distintos, y ninguna esta a
#  la vista. Este archivo junta esos datos y los muestra cuando hacen falta.
#
#  Vive aca separado de comun.sh, y no adentro, por lo mismo que avisos.sh: asi
#  el instalador y el ./movil.sh de la raiz dicen EXACTAMENTE lo mismo. Con dos
#  copias, en tres meses una queda vieja y no hay forma de saber cual.
#
#  Todas las direcciones que salen de aca van por Caddy, en el puerto 80 y con
#  el nombre .pi. Nunca la IP con el puerto interno del servicio, que es lo que
#  dice cualquier tutorial de internet y lo que NO funciona: esos puertos estan
#  cerrados a la red de casa a proposito, y el sintoma de equivocarse es un
#  tiempo de espera agotado que parece un problema de la app.
# ==============================================================================

# ── El catalogo ───────────────────────────────────────────────────────────────
#
#  clave | nombre | plataforma | para que sirve
#
#  El orden importa: se ofrece de lo mas util a lo mas de nicho, para que quien
#  se cansa a la mitad se haya llevado lo que mas le sirve.
MOVIL_APPS=(
"homepage|La homepage como app|iOS y Android|Todos tus servicios detras de un icono, sin instalar nada de nadie"
"casa|Home Assistant|iOS y Android, oficial|Tu casa desde el celular, con avisos que llegan de verdad"
"jellyfin|Jellyfin|iOS y Android, oficial|Tus peliculas y series, y tambien para tirarlas a la tele"
"ntfy|ntfy|iOS y Android|Los avisos de la casa cuando algo se rompe"
"helmarr|Helmarr|solo iOS|Radarr, Sonarr, Prowlarr, Bazarr, Seerr y qBittorrent en una sola app"
"pihole|Pi-hole Remote|solo iOS|Apagar el bloqueo un rato sin levantarte a buscar la computadora"
"wallabag|Wallabag|iOS y Android, oficial|Tus articulos guardados, y se leen sin conexion"
"rss|Un lector de RSS|iOS y Android|FreshRSS desde una app de verdad, no desde el navegador"
)

# ── Que tiene sentido ofrecerte ───────────────────────────────────────────────
#
#  Se mira lo que esta CORRIENDO, no lo que elegiste en el menu. Este archivo
#  tambien se usa desde ./movil.sh mucho despues de instalar, cuando la lista
#  de lo elegido ya no existe en ningun lado.
movil_aplica() {
    case "$1" in
        homepage) esta_arriba homepage ;;
        casa)     esta_arriba homeassistant ;;
        jellyfin) esta_arriba jellyfin ;;
        helmarr)  esta_arriba radarr || esta_arriba sonarr || esta_arriba seerr ;;
        pihole)   command -v pihole >/dev/null 2>&1 ;;
        wallabag) esta_arriba wallabag ;;
        rss)      esta_arriba freshrss ;;
        ntfy)     [ -n "$(leer_var "$REPO/.env" NTFY_ALERTAS 2>/dev/null)" ] ;;
        *)        return 1 ;;
    esac
}

# ── De donde sale cada clave ──────────────────────────────────────────────────
#
#  Cada servicio la guarda a su manera y en su propio volumen. Se leen en el
#  momento y no se copian a ningun lado: una clave duplicada es una clave que
#  algun dia va a quedar vieja sin que nadie se entere.

# Radarr, Sonarr y Prowlarr comparten el mismo XML de configuracion
_movil_arr_key() {
    local cfg; cfg=$(ruta_config "$1" 2>/dev/null)
    [ -n "$cfg" ] || return 1
    sudo grep -oP "(?<=<ApiKey>)[^<]+" "$cfg/config.xml" 2>/dev/null
}

_movil_bazarr_key() {
    local cfg; cfg=$(ruta_config bazarr 2>/dev/null)
    [ -n "$cfg" ] || return 1
    sudo grep -oP "^\s*apikey:\s*\K\S+" "$cfg/config/config.yaml" 2>/dev/null \
        | head -1 | tr -d "\047\042"
}

_movil_seerr_key() {
    local cfg; cfg=$(ruta_config seerr 2>/dev/null)
    [ -n "$cfg" ] || return 1
    sudo python3 -c "
import json,sys
try:
    print(json.load(open(sys.argv[1]))['main']['apiKey'])
except Exception:
    pass
" "$cfg/settings.json" 2>/dev/null
}

# Pi-hole v6 no usa un token fijo como v5: usa la contrasena del panel, o una
# contrasena de aplicacion aparte, que es la que crea el instalador. Se prefiere
# la de aplicacion porque se puede revocar sola, sin tocar la del panel.
_movil_pihole_key() {
    leer_var "$REPO/monitoring/.env" PIHOLE_API_KEY 2>/dev/null
}

_movil_falta() {
    echo "  ${A}!${N} no la encontre. Esta en ${B}$1${N}"
}

# ── Los datos de cada una ─────────────────────────────────────────────────────

_movil_dato()  { printf "     %-12s %s\n" "$1" "$2"; }

movil_datos() {
    local k
    case "$1" in

    homepage)
        info "No se instala: se agrega la pagina a la pantalla de inicio."
        echo ""
        _movil_dato "Direccion" "http://homepage.pi"
        _movil_dato "Usuario" "admin"
        _movil_dato "Contrasena" "la general que elegiste"
        echo ""
        gris "     En el celular, abri esa direccion, toca Compartir y elegi"
        gris "     ${B}Agregar a inicio${N}. Queda un icono y se abre a pantalla"
        gris "     completa, sin la barra del navegador."
        gris "     Sirve igual para cualquier otro servicio de la lista."
        ;;

    casa)
        info "Busca ${B}Home Assistant${N} en la tienda. Es la app oficial."
        echo ""
        _movil_dato "Direccion" "http://casa.pi"
        echo ""
        gris "     Al agregar el servidor, elegi escribir la direccion a mano."
        gris "     La que te ofrece sola es la IP con el puerto 8123, y ese"
        gris "     puerto esta cerrado a la red de casa: da tiempo de espera"
        gris "     agotado y parece que la app estuviera rota."
        ;;

    jellyfin)
        info "Busca ${B}Jellyfin${N} en la tienda. Es la app oficial."
        echo ""
        _movil_dato "Direccion" "http://jellyfin.pi"
        _movil_dato "Usuario" "admin"
        _movil_dato "Contrasena" "la general que elegiste"
        echo ""
        gris "     Si tu tele no tiene la app de Jellyfin, desde el celular la"
        gris "     podes mandar a la tele por AirPlay o Chromecast."
        ;;

    ntfy)
        info "Busca ${B}ntfy${N} en la tienda. Gratis y sin crear cuenta."
        echo ""
        _movil_dato "Servidor" "${NTFY_SERVIDOR:-https://ntfy.sh}"
        _movil_dato "Canales" "los ves con ${B}./avisos.sh --canales${N}"
        echo ""
        gris "     El nombre del canal es la contrasena: quien lo sabe, escucha."
        ;;

    helmarr)
        info "Busca ${B}Helmarr${N} en la App Store. Con una sola app manejas"
        info "todo el grupo, y se conecta directo a tu casa sin intermediarios."
        echo ""
        local svc nom
        for svc in radarr sonarr prowlarr; do
            esta_arriba "$svc" || continue
            nom=$svc
            k=$(_movil_arr_key "$svc")
            echo "  ${B}$nom${N}"
            _movil_dato "URL" "http://$nom.pi"
            if [ -n "$k" ]; then
                _movil_dato "Clave" "$k"
            else
                _movil_falta "el panel de $nom, en Settings General"
            fi
            echo ""
        done
        if esta_arriba bazarr; then
            k=$(_movil_bazarr_key)
            echo "  ${B}bazarr${N}"
            _movil_dato "URL" "http://bazarr.pi"
            [ -n "$k" ] && _movil_dato "Clave" "$k" || _movil_falta "Bazarr, en Settings General"
            echo ""
        fi
        if esta_arriba seerr; then
            k=$(_movil_seerr_key)
            echo "  ${B}seerr${N}"
            _movil_dato "URL" "http://seerr.pi"
            [ -n "$k" ] && _movil_dato "Clave" "$k" || _movil_falta "Seerr, en Settings General"
            echo ""
        fi
        if esta_arriba qbittorrent; then
            echo "  ${B}qbittorrent${N}  (este va con usuario, no con clave de API)"
            _movil_dato "URL" "http://qbit.pi"
            _movil_dato "Usuario" "admin"
            _movil_dato "Contrasena" "la general que elegiste"
            echo ""
        fi
        gris "     No le pongas servidor secundario: estos nombres resuelven"
        gris "     igual en casa que por Tailscale, asi que la misma direccion"
        gris "     sirve para los dos lados."
        ;;

    pihole)
        info "Busca ${B}Pi-hole Remote${N} en la App Store. Deja apagar el"
        info "bloqueo desde la pantalla bloqueada, que es cuando lo necesitas."
        echo ""
        k=$(_movil_pihole_key)
        _movil_dato "Direccion" "http://pihole.pi"
        _movil_dato "Puerto" "80"
        _movil_dato "SSL" "desactivado"
        if [ -n "$k" ]; then
            _movil_dato "Contrasena" "$k"
            echo ""
            gris "     Esa no es la contrasena de tu panel: es una de aplicacion,"
            gris "     aparte, hecha para esto. Si algun dia queres cortarle el"
            gris "     acceso a la app, la revocas sin tocar la tuya."
        else
            _movil_dato "Contrasena" "la del panel de Pi-hole"
        fi
        ;;

    wallabag)
        info "Busca ${B}wallabag${N} en la tienda. Es la app oficial."
        echo ""
        _movil_dato "Direccion" "http://wallabag.pi"
        _movil_dato "Usuario" "admin"
        echo ""
        gris "     Te va a pedir tambien un cliente de API, que se crea desde"
        gris "     el propio Wallabag en Configuracion, Clientes de API."
        ;;

    rss)
        info "FreshRSS habla el protocolo de Google Reader, asi que lo lee"
        info "cualquier lector serio: ${B}NetNewsWire${N} (gratis y de codigo"
        info "abierto), Reeder, Unread o Fiery Feeds."
        echo ""
        _movil_dato "Direccion" "http://freshrss.pi/api/greader.php"
        _movil_dato "Usuario" "admin"
        _movil_dato "Contrasena" "la de la API, NO la de entrar al sitio"
        echo ""
        gris "     La contrasena de API es otra y se pone en FreshRSS, en"
        gris "     Configuracion, Perfil, Contrasena de la API."
        ;;

    esac
}

# ── Que quedo hecho y que no ──────────────────────────────────────────────────
#
#  Se anota si conseguiste configurar cada app, y sirve para dos cosas.
#
#  La primera es no hacerte perder el tiempo: volver a correr el instalador no
#  tiene que volver a ofrecerte las cinco apps que ya tenes andando.
#
#  La segunda importa mas. Mostrar unos datos en pantalla no es lo mismo que
#  que la app quede funcionando, y hasta ahora la unica forma de saberlo era
#  acordarse. Preguntando queda la diferencia entre "te lo dije" y "te funciono",
#  y lo que no funciono queda como pendiente en vez de perderse.
#
#  Es una anotacion tuya, no una verdad del sistema: si decis que anduvo, se
#  cree. Comprobar de verdad exigiria hablar con tu telefono, que no se puede.
#  Se guarda con la fecha, no solo el si o el no. Un "ya la configuraste" pelado
#  no se puede discutir: si la app no anda hoy, querés saber de cuando es esa
#  afirmacion, porque una anotacion de hace ocho meses y un cambio de telefono
#  en el medio explican bastante.
MOVIL_ESTADO="$DATOS/movil-estado"

_movil_marcar()    { _av_escribir "$MOVIL_ESTADO" "$1" "$2|$(date '+%Y-%m-%d %H:%M')" 2>/dev/null; }
_movil_estado_de() { _av_leer "$MOVIL_ESTADO" "$1" 2>/dev/null | cut -d'|' -f1; }
_movil_cuando_de() { _av_leer "$MOVIL_ESTADO" "$1" 2>/dev/null | cut -s -d'|' -f2-; }

# ── El recorrido ──────────────────────────────────────────────────────────────
#
#  De a una y preguntando. Escupir las ocho juntas seria mas corto de programar
#  y peor de usar: son treinta lineas de claves que nadie lee, y las dos que te
#  servian quedan enterradas entre las seis que no.
configurar_movil() {
    local app clave nombre plataforma para estado cuando
    local n=0 ya=0 nuevas=0 fallaron=0

    for app in "${MOVIL_APPS[@]}"; do
        IFS='|' read -r clave nombre plataforma para <<< "$app"
        movil_aplica "$clave" || continue
        n=$((n+1))
        [ "$(_movil_estado_de "$clave")" = "listo" ] && ya=$((ya+1))
    done

    if [ "$n" -eq 0 ]; then
        info "Todavia no hay nada corriendo que se use desde el celular."
        return 0
    fi

    echo ""
    echo "  ${B}${C}Desde el celular${N}"
    echo ""
    info "Hay ${B}$n${N} $(plural "$n" "app que te sirve" "apps que te sirven") para lo que"
    info "tenes instalado. Van de a una: te digo para que sirve cada una y,"
    info "si la queres, te paso los datos listos para copiar."
    if [ "$ya" -gt 0 ]; then
        gris "     $ya $(plural "$ya" "ya la tenias configurada" "ya las tenias configuradas"), esas las paso rapido."
    fi
    echo ""

    for app in "${MOVIL_APPS[@]}"; do
        IFS='|' read -r clave nombre plataforma para <<< "$app"
        movil_aplica "$clave" || continue
        estado=$(_movil_estado_de "$clave")

        cuando=$(_movil_cuando_de "$clave")

        if [ "$estado" = "listo" ]; then
            ok "${B}$nombre${N}  ${G}ya la configuraste${N}"
            gris "     Tengo anotado que te funcionaba${cuando:+ el $cuando}."
            preguntar "     ¿Te la paso igual?" "n" || { echo ""; continue; }
        else
            echo "  ${B}$nombre${N}  ${G}·  $plataforma${N}"
            gris "     $para"
            [ "$estado" = "no" ] && \
                gris "     Quedo a medias${cuando:+ el $cuando}, asi que la vuelvo a ofrecer."
            preguntar "     ¿Te paso los datos?" "s" || { echo ""; continue; }
        fi

        echo ""
        movil_datos "$clave"
        echo ""

        if preguntar "     ¿Te quedo funcionando?" "s"; then
            [ "$estado" = "listo" ] || nuevas=$((nuevas+1))
            _movil_marcar "$clave" listo
            ok "Anotado"
        else
            fallaron=$((fallaron+1))
            _movil_marcar "$clave" no
            gris "     Queda anotado. Retomas donde quedaste con ${B}./movil.sh${N}."
            declare -F pendiente >/dev/null 2>&1 && \
                pendiente "Terminar de configurar $nombre en el celular: ./movil.sh"
        fi
        echo ""
    done

    [ "$nuevas" -gt 0 ]   && ok "$nuevas $(plural "$nuevas" "app nueva andando" "apps nuevas andando")"
    [ "$fallaron" -gt 0 ] && aviso "$fallaron $(plural "$fallaron" "quedo pendiente" "quedaron pendientes")"
    gris "     Para retomar esto cuando quieras:  ${B}./movil.sh${N}"
    echo ""
    return 0
}
