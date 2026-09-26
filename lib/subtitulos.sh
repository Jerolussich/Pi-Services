#!/bin/bash
# ==============================================================================
#  lib/subtitulos.sh  ·  Ofrecer proveedores de Bazarr, explicados y de a uno
#
#  No se ejecuta solo: se carga con source desde comun.sh.
#
#  Bazarr con el perfil de idiomas puesto y sin un solo proveedor no baja nada:
#  sabe que subtitulo quiere y no tiene de donde sacarlo. Y elegir proveedores
#  de una lista de 65 nombres, sin saber cual habla español ni cual pide
#  cuenta, no es una eleccion informada.
#
#  Aca hay una lista corta con lo unico que importa para decidir: si sirve para
#  lo que mirás, si pide cuenta, y donde se saca esa cuenta si la pide.
#
#  La distincion entre los dos grupos es la que manda:
#
#  Sin cuenta  → se activan solos y dejan subtitulos andando de entrada.
#  Con cuenta  → se piden los datos, y si no los tenes a mano se saltea y
#                queda anotado, con la direccion donde registrarte. Nunca se
#                deja un proveedor activado a medias, que es peor que no
#                tenerlo: figura activo y falla en silencio en cada busqueda.
# ==============================================================================

# id|Nombre|cuenta|donde se saca|campos|para que sirve
#
# cuenta:  no = anda sin registrarse  ·  si = hay que crear una cuenta
# campos:  los de la API de Bazarr, separados por coma, vacio si no pide nada
BAZARR_CATALOGO=(
"opensubtitlescom|OpenSubtitles.com|si|https://www.opensubtitles.com|username,password|El mas grande y el que mejor cubre español. La cuenta gratuita da unas 20 descargas por dia, que alcanza salvo que cargues la biblioteca entera de golpe"
"subtitulamostv|Subtitulamos.tv|no|||Comunidad hispana, ${B}solo series${N}. Publican los episodios muy rapido y en español nativo, no traducido"
"subtis|Subtis|no|||Proyecto argentino, ${B}solo peliculas${N}. Busca por hash del archivo, asi que lo que encuentra viene sincronizado"
"embeddedsubtitles|Subtitulos embebidos|no|||No baja nada de internet: saca los subtitulos que ${B}ya vienen adentro${N} del archivo. Gratis en todo sentido y no depende de ningun servidor. Conviene tenerlo siempre"
"yifysubtitles|YifySubtitles|no|||Subtitulos hechos para los releases de YTS. Tiene sentido si cargaste YTS como indexer"
"subf2m|Subf2m|no|||Heredero de Subscene, catalogo grande y con buen español. Sin cuenta"
"subdl|SubDL|si|https://subdl.com|api_key|Multiidioma y moderno. Pide una clave de API que se saca gratis en tu perfil"
)

# ── Lo que Bazarr ya tiene ────────────────────────────────────────────────────

bazarr_activos() {
    local ip="$1" key="$2"
    curl -s --max-time 20 -H "X-API-KEY: $key" "http://$ip:6767/api/system/settings" 2>/dev/null \
        | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    for p in (d.get("general", {}).get("enabled_providers") or []): print(p)
except Exception:
    pass' 2>/dev/null
}

# Guarda la lista completa de activos. Bazarr espera el parametro repetido, uno
# por proveedor, igual que con los idiomas.
bazarr_guardar_activos() {
    local ip="$1" key="$2"; shift 2
    local p args=() code
    for p in "$@"; do args+=(--data-urlencode "settings-general-enabled_providers=$p"); done
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 40 -X POST -H "X-API-KEY: $key" \
        "${args[@]}" "http://$ip:6767/api/system/settings" 2>/dev/null)
    case "$code" in 200|204) return 0 ;; *) return 1 ;; esac
}

# Los datos de cuenta de un proveedor van en su propia seccion.
bazarr_guardar_credenciales() {
    local ip="$1" key="$2" prov="$3" creds="$4"
    local par args=() code
    for par in ${creds//;/ }; do
        [ -n "$par" ] || continue
        args+=(--data-urlencode "settings-$prov-${par%%=*}=${par#*=}")
    done
    [ ${#args[@]} -gt 0 ] || return 0
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 40 -X POST -H "X-API-KEY: $key" \
        "${args[@]}" "http://$ip:6767/api/system/settings" 2>/dev/null)
    case "$code" in 200|204) return 0 ;; *) return 1 ;; esac
}

# ── La eleccion ───────────────────────────────────────────────────────────────

configurar_proveedores_subtitulos() {
    esta_arriba bazarr || return 0
    local ip key; ip=$(ip_de bazarr); key=$(api_key_bazarr)
    [ -n "$ip" ] && [ -n "$key" ] || return 0

    local activos nuevos=() linea id nombre cuenta donde campos para
    local ofrecidos=0 puestos=0
    activos=$(bazarr_activos "$ip" "$key")

    for linea in "${BAZARR_CATALOGO[@]}"; do
        id="${linea%%|*}"
        echo "$activos" | grep -qxF "$id" || ofrecidos=$((ofrecidos+1))
    done

    if [ "$ofrecidos" -eq 0 ]; then
        gris "     los proveedores de subtitulos recomendados ya estan puestos"
        return 0
    fi

    echo ""
    info "Bazarr tiene 65 proveedores y ninguno activado de fabrica."
    info "Te ofrezco ${B}$ofrecidos${N} que sirven para español, de a uno."
    gris "     Los que no piden cuenta quedan andando en el momento."
    echo ""

    for linea in "${BAZARR_CATALOGO[@]}"; do
        IFS='|' read -r id nombre cuenta donde campos para <<< "$linea"
        echo "$activos" | grep -qxF "$id" && continue

        # La etiqueta y el sitio van ANTES de la descripcion: que haya que
        # registrarse en algun lado es lo primero que cambia la respuesta, y
        # verlo despues de decir que si es tarde.
        if [ "$cuenta" = "si" ]; then
            echo "  ${B}$nombre${N}   ${A}necesita cuenta en $donde${N}"
        else
            echo "  ${B}$nombre${N}   ${G}sin cuenta${N}"
        fi
        gris "     $para"

        if ! preguntar "     ¿Lo activo?" "n"; then echo ""; continue; fi

        local creds="" campo valor faltan=0
        if [ "$cuenta" = "si" ]; then
            echo ""
            info "     Sacá la cuenta en ${B}$donde${N} y copiá los datos aca."
            gris "     Si no la tenes ahora, apreta Enter y lo salteo: lo podes"
            gris "     activar despues en http://bazarr.pi, Settings, Providers."
            for campo in ${campos//,/ }; do
                if [ "$campo" = "password" ]; then
                    read -r -s -p "        $campo: " valor </dev/tty; echo ""
                else
                    read -r -p "        $campo: " valor </dev/tty
                fi
                if [ -z "$valor" ]; then faltan=1; break; fi
                creds="$creds$campo=$valor;"
            done
            if [ "$faltan" = "1" ]; then
                info "     Lo salteo."
                pendiente "Activar $nombre en http://bazarr.pi con tu cuenta de $donde"
                echo ""
                continue
            fi
            if ! bazarr_guardar_credenciales "$ip" "$key" "$id" "$creds"; then
                aviso "     Bazarr no acepto los datos de $nombre"
                pendiente "Cargar la cuenta de $nombre en http://bazarr.pi, Settings, Providers"
                echo ""
                continue
            fi
        fi

        nuevos+=("$id")
        puestos=$((puestos+1))
        ok "$nombre activado"
        echo ""
    done

    if [ "$puestos" -gt 0 ]; then
        # Se guarda TODA la lista de una: la de antes mas las nuevas. Mandar
        # solo las nuevas borraria las que ya estaban.
        local todas=()
        while read -r id; do [ -n "$id" ] && todas+=("$id"); done <<< "$activos"
        todas+=("${nuevos[@]}")
        if bazarr_guardar_activos "$ip" "$key" "${todas[@]}"; then
            ok "$puestos $(plural "$puestos" "proveedor activo" "proveedores activos") en Bazarr"
        else
            aviso "Bazarr no acepto la lista de proveedores"
            pendiente "Activar los proveedores en http://bazarr.pi, Settings, Providers"
        fi
    fi
    return 0
}
