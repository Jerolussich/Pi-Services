# ==============================================================================
#  LOS PLUGINS DE JELLYFIN
#
#  Jellyfin viene bastante pelado a proposito y casi todo lo interesante es un
#  plugin. El catalogo tiene mas de treinta, con nombres en ingles y
#  descripciones de una linea que no dicen para que te sirve a VOS.
#
#  Asi que se ofrece una seleccion, con la explicacion en criollo, y se pregunta
#  de a uno.
#
#  ── Dos decisiones que explican el resto ─────────────────────────────────────
#
#  1. La lista NO esta clavada aca. Se le pregunta al propio Jellyfin que tiene
#     disponible y se ofrece la interseccion con esta seleccion.
#
#     Eso resuelve solo el problema de las versiones: los plugins declaran para
#     que version de Jellyfin son, y el servidor no ofrece los que no le sirven.
#     Con una lista clavada, el instalador ofreceria plugins que no cargan y el
#     sintoma seria un plugin instalado que simplemente no aparece.
#
#  2. NO se agregan repositorios externos. Los mejores plugins de la comunidad
#     viven fuera del catalogo oficial, pero sus manifiestos se mudan: el de
#     Intro Skipper, sin ir mas lejos, hoy redirige a una pagina de GitHub y ya
#     no sirve JSON. Un repositorio muerto clavado en el instalador falla en
#     silencio y no hay forma de que te enteres. Esos siguen a mano, y estan
#     explicados en media/JELLYFIN-PLUGINS.md.
# ==============================================================================

# ── La seleccion ──────────────────────────────────────────────────────────────
#
#  nombre exacto en el catalogo | para que te sirve
#
#  El nombre tiene que coincidir tal cual con el del catalogo, porque es lo que
#  se le manda a la API. Los de aca estan tomados del manifiesto oficial.
#
#  El orden es el de utilidad real para este stack: primero los que resuelven
#  algo que hoy te falta, despues los lindos.
JF_PLUGINS=(
"DLNA|Que la tele te vea sin instalarle ninguna app. Sirve justo cuando tu tele no tiene la app de Jellyfin"
"Playback Reporting|Estadisticas de que se vio, cuanto y quien. Lo unico que te dice si vale la pena tener algo bajado"
"TMDb Box Sets|Junta solo las sagas en una coleccion. Las ocho de Star Wars dejan de ser ocho fichas sueltas"
"Subtitle Extract|Saca los subtitulos que vienen adentro del archivo y los deja como pista aparte, que carga mucho mas rapido"
"Transcode Killer|Corta las conversiones que le piden mas de lo que el equipo puede. Sin esto, un solo cliente exigente pone la casa entera a tironear"
"Reports|Listados de la biblioteca: que no tiene caratula, que le falta metadata, que esta duplicado"
"Webhook|Avisa a otro programa cuando pasa algo. Es la pieza para que Jellyfin te mande cosas al celular"
"Trakt|Sincroniza lo que ves con tu cuenta de trakt.tv, si tenes una"
"Session Cleaner|Limpia las sesiones de aparatos que ya no existen y quedan colgadas para siempre"
"Open Subtitles|Baja subtitulos de internet. OJO: Bazarr ya hace esto y mejor, asi que solo si no lo tenes"
)

# ── Que hay y que ya esta puesto ──────────────────────────────────────────────

# Los nombres que el servidor dice tener disponibles, uno por linea.
jf_plugins_del_catalogo() {
    jf_api GET /Packages 2>/dev/null | python3 -c '
import sys, json
try:
    for p in json.load(sys.stdin):
        n = p.get("name")
        if n: print(n)
except Exception:
    pass' 2>/dev/null
}

# Los que ya estan instalados, uno por linea.
jf_plugins_instalados() {
    jf_api GET /Plugins 2>/dev/null | python3 -c '
import sys, json
try:
    for p in json.load(sys.stdin):
        n = p.get("Name") or p.get("name")
        if n: print(n)
except Exception:
    pass' 2>/dev/null
}

# ── Instalar uno ──────────────────────────────────────────────────────────────
#
#  Jellyfin lo baja e instala en segundo plano y no queda activo hasta
#  reiniciarlo, asi que no alcanza con que el POST no falle: se relee la lista
#  de instalados. Aparecer ahi es lo que significa que quedo.
jf_plugin_instalar() {
    local nombre="$1" i

    # El nombre va en la URL y tiene espacios
    jf_api POST "/Packages/Installed/$(printf '%s' "$nombre" | sed 's/ /%20/g')" "" >/dev/null 2>&1

    # Se reintenta: la instalacion es asincrona y tarda lo que tarde la descarga
    for i in 1 2 3 4 5 6; do
        sleep 2
        if jf_plugins_instalados | grep -qxF "$nombre"; then
            return 0
        fi
    done
    return 1
}

# ── El recorrido ──────────────────────────────────────────────────────────────

configurar_plugins_jellyfin() {
    local disponibles instalados par nombre para
    local ofrecidos=0 puestos=0 fallaron=0 hay_nuevos=0

    [ -n "${JF_TOKEN:-}" ] || return 0

    disponibles=$(jf_plugins_del_catalogo)
    if [ -z "$disponibles" ]; then
        gris "     no pude leer el catalogo de plugins, lo salteo"
        return 0
    fi
    instalados=$(jf_plugins_instalados)

    # Cuantos tiene sentido ofrecerte: los de la seleccion que el servidor
    # tenga y que no esten ya puestos.
    for par in "${JF_PLUGINS[@]}"; do
        nombre="${par%%|*}"
        echo "$disponibles" | grep -qxF "$nombre" || continue
        echo "$instalados"  | grep -qxF "$nombre" && continue
        ofrecidos=$((ofrecidos+1))
    done

    if [ "$ofrecidos" -eq 0 ]; then
        gris "     los plugins que valen la pena ya estan puestos"
        return 0
    fi

    echo ""
    info "Jellyfin viene pelado a proposito: casi todo lo interesante es un"
    info "plugin. Te ofrezco ${B}$ofrecidos${N} que tiene sentido tener, de a uno."
    gris "     Se instalan en el momento pero recien andan al reiniciar Jellyfin,"
    gris "     cosa que hago yo al final si instalas alguno."
    echo ""

    for par in "${JF_PLUGINS[@]}"; do
        IFS='|' read -r nombre para <<< "$par"
        echo "$disponibles" | grep -qxF "$nombre" || continue
        if echo "$instalados" | grep -qxF "$nombre"; then continue; fi

        echo "  ${B}$nombre${N}"
        gris "     $para"
        if ! preguntar "     ¿Lo instalo?" "n"; then
            echo ""
            continue
        fi

        if jf_plugin_instalar "$nombre"; then
            ok "$nombre instalado"
            puestos=$((puestos+1))
            hay_nuevos=1
        else
            aviso "$nombre: no pude instalarlo"
            gris "     lo podes poner desde http://jellyfin.pi, Dashboard, Plugins"
            fallaron=$((fallaron+1))
        fi
        echo ""
    done

    # Reiniciar UNA vez al final y no despues de cada uno: cada reinicio son
    # veinte segundos de servidor caido, y no hay ningun motivo para pagarlos
    # tres veces seguidas.
    if [ "$hay_nuevos" = "1" ]; then
        info "Reinicio Jellyfin una sola vez para que tomen efecto..."
        $DOCKER restart jellyfin >/dev/null 2>&1
        if esperar_http jellyfin 8096 /System/Info/Public; then
            ok "$puestos $(plural "$puestos" "plugin andando" "plugins andando")"
        else
            aviso "Jellyfin no volvio a levantar despues de reiniciar"
            pendiente "Revisar Jellyfin:  docker logs jellyfin"
        fi
    fi

    [ "$fallaron" -gt 0 ] && \
        pendiente "Instalar $fallaron $(plural "$fallaron" "plugin" "plugins") de Jellyfin a mano"

    gris "     Los de la comunidad, como Intro Skipper, van a mano y estan"
    gris "     explicados en ${B}media/JELLYFIN-PLUGINS.md${N}"
    echo ""
    return 0
}
