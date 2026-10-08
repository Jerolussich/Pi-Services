#!/bin/bash
# ==============================================================================
#  lib/indexers.sh  ·  Ofrecer indexers de Prowlarr, explicados y de a uno
#
#  No se ejecuta solo: se carga con source desde comun.sh.
#
#  Cargar indexers era uno de los pasos que quedaban para vos, y es el que mas
#  cuesta: Prowlarr trae 636 en el catalogo, sin ningun orden, y la unica
#  diferencia visible entre uno bueno y uno muerto es el nombre. Encima el
#  formulario tiene una trampa: baseUrl es un desplegable sin valor por
#  defecto, y si no lo elegis el Test pasa igual pero el Save falla.
#
#  Aca hay una lista corta de los que valen la pena, con una linea de para que
#  sirve cada uno, y se agregan por API con el dominio oficial ya puesto.
#
#  Lo que este archivo NO hace es adivinar. El catalogo de abajo solo guarda la
#  descripcion, que es lo unico que una persona tiene que escribir; todo lo
#  demas -si existe, si es publico o privado, si necesita FlareSolverr, cual es
#  su dominio- se le pregunta a Prowlarr en el momento. Asi el dia que un
#  indexer cambie de dominio o se caiga del catalogo, esto no miente.
# ==============================================================================

# nombre exacto en Prowlarr|para que sirve
#
# Ojo con el nombre: el de anime figura como "Nyaa.si", no como "Nyaa". Una
# busqueda por "Nyaa" a secas no lo encuentra y parece que no existe. Al lado
# esta "sukebei.nyaa.si", que es contenido adulto: no confundirlos.
#
# El nombre tiene que coincidir exacto con el del catalogo de Prowlarr. Si no
# coincide, no se ofrece y no pasa nada: es preferible a ofrecer algo que no
# existe.
PROWLARR_CATALOGO=(
"1337x|General, el mas completo y con los nombres mas prolijos. Peliculas y series. Es el que mas veces va a ganar la eleccion"
"The Pirate Bay|Catalogo enorme, pero con nombres sucios: Radarr descarta bastantes resultados por no poder leerlos. Sirve de red para lo que no aparece en ningun otro lado"
"YTS|Solo peliculas, en x265 y livianas. Comodo si la conexion no sobra, aunque casi siempre pierde contra una version de mejor calidad"
"EZTV|Solo series, muy consistente y rapido publicando episodios nuevos. Es el companero natural de Sonarr"
"Nyaa.si|Anime, el estandar del rubro: series y peliculas, con los grupos de fansub y los releases japoneses. Solo tiene sentido si mirás anime"
)

# LimeTorrents estuvo aca y se fue. Probandolo contra la instalacion real,
# Radarr lo rechaza con 400 al sincronizarlo:
#
#   "Query successful, but no results in the configured categories were
#    returned from your indexer."
#
# Devuelve resultados para series pero no para peliculas, asi que entra en
# Sonarr y falla en Radarr. Un indexer que se agrega bien en Prowlarr y despues
# no llega a la mitad de las apps es peor que no ofrecerlo: parece que quedo
# puesto y no aparece por ningun lado.

# ── Lo que Prowlarr sabe de cada uno ──────────────────────────────────────────

# El catalogo entero, una sola vez: son 636 entradas y no tiene sentido pedirlo
# entre cada pregunta.
PROWLARR_SCHEMA_CACHE=""

prowlarr_schema() {
    [ -n "$PROWLARR_SCHEMA_CACHE" ] && { echo "$PROWLARR_SCHEMA_CACHE"; return 0; }
    PROWLARR_SCHEMA_CACHE=$(arr_api prowlarr 9696 v1 GET /indexer/schema 2>/dev/null)
    echo "$PROWLARR_SCHEMA_CACHE"
}

# Los que ya estan cargados, uno por linea, para no volver a ofrecerlos.
prowlarr_ya_cargados() {
    arr_api prowlarr 9696 v1 GET /indexer 2>/dev/null | python3 -c '
import sys, json
try:
    for x in json.load(sys.stdin): print(x.get("name", ""))
except Exception:
    pass' 2>/dev/null
}

# Devuelve "privacy|necesita_flare|url|campos_de_credencial" de un indexer, o
# vacio si no esta en el catalogo.
prowlarr_ficha() {
    local nombre="$1"
    prowlarr_schema | NOMBRE="$nombre" python3 -c '
import sys, json, os
n = os.environ["NOMBRE"]
try: d = json.load(sys.stdin)
except Exception: sys.exit()
s = next((x for x in d if x.get("name") == n), None)
if not s: sys.exit()

# Los indexers detras de Cloudflare traen un campo de aviso en su definicion.
# Es la misma fuente que usa la interfaz para mostrar el recuadro azul.
flare = any("flare" in f["name"].lower() or "flaresolver" in str(f.get("value", "")).lower()
            for f in s.get("fields", []))

# Un campo de credencial es el que la definicion deja vacio y se llama como se
# llaman estas cosas. No se adivina por el tipo: hay textbox que son opciones.
claves = [f["name"] for f in s.get("fields", [])
          if any(k in f["name"].lower() for k in ("username", "password", "apikey", "api_key", "passkey", "cookie", "rsskey"))]

urls = s.get("indexerUrls") or []
print("|".join([s.get("privacy", "?"), "si" if flare else "no",
                urls[0] if urls else "", ",".join(claves)]))' 2>/dev/null
}

# ── Agregar uno ───────────────────────────────────────────────────────────────

# El tag de FlareSolverr, creandolo si hace falta. Sin el, un indexer detras de
# Cloudflare se agrega igual y despues falla en cada busqueda.
prowlarr_tag_flare() {
    local tags id
    tags=$(arr_api prowlarr 9696 v1 GET /tag 2>/dev/null)
    id=$(echo "$tags" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = []
print(next((t["id"] for t in d if t.get("label") == "flaresolverr"), ""))' 2>/dev/null)
    if [ -z "$id" ]; then
        id=$(arr_api prowlarr 9696 v1 POST /tag '{"label":"flaresolverr"}' 2>/dev/null \
            | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
    fi
    echo "$id"
}

# El perfil de sincronizacion, que en el formulario es el desplegable "Sync
# Profile". El schema lo trae en 0 y Prowlarr rechaza el alta con
# "'App Profile Id' must be greater than '0'", un error que no dice en ningun
# lado que se trata de ese desplegable.
prowlarr_app_profile() {
    arr_api prowlarr 9696 v1 GET /appprofile 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = []
print(d[0]["id"] if d else "")' 2>/dev/null
}

# $1 nombre  $2 url base  $3 id de tag o vacio  $4 credenciales "campo=valor;campo=valor"
prowlarr_agregar() {
    local nombre="$1" url="$2" tag="$3" creds="$4" cuerpo resp perfil
    perfil=$(prowlarr_app_profile)
    [ -n "$perfil" ] || { aviso "Prowlarr no tiene ningun perfil de sincronizacion"; return 1; }

    cuerpo=$(prowlarr_schema | NOMBRE="$nombre" URL="$url" TAG="$tag" CREDS="$creds" PERFIL="$perfil" python3 -c '
import sys, json, os
n = os.environ["NOMBRE"]
d = json.load(sys.stdin)
s = next((x for x in d if x.get("name") == n), None)
if not s: sys.exit(1)

puestas = {}
for par in os.environ.get("CREDS", "").split(";"):
    if "=" in par:
        k, _, v = par.partition("=")
        puestas[k] = v

for f in s.get("fields", []):
    if f["name"] == "baseUrl":
        f["value"] = os.environ["URL"]
    elif f["name"] in puestas:
        f["value"] = puestas[f["name"]]

s["tags"] = [int(os.environ["TAG"])] if os.environ.get("TAG") else []
s["enable"] = True
s["appProfileId"] = int(os.environ["PERFIL"])
print(json.dumps(s))' 2>/dev/null)

    [ -n "$cuerpo" ] || return 1
    arr_api prowlarr 9696 v1 POST /indexer "$cuerpo" >/dev/null 2>&1

    # Se relee en vez de creer en la respuesta: curl sale con 0 aunque Prowlarr
    # conteste 400, asi que el codigo de salida no dice nada.
    resp=$(prowlarr_ya_cargados)
    echo "$resp" | grep -qxF "$nombre"
}

# ── La eleccion ───────────────────────────────────────────────────────────────

configurar_indexers() {
    local par nombre para ficha privacy flare url claves
    local cargados ofrecidos=0 puestos=0

    esperar_http prowlarr 9696 /api/v1/system/status || return 0
    [ -n "$(prowlarr_schema)" ] || { gris "     no pude leer el catalogo de indexers, lo salteo"; return 0; }

    cargados=$(prowlarr_ya_cargados)

    for par in "${PROWLARR_CATALOGO[@]}"; do
        nombre="${par%%|*}"
        echo "$cargados" | grep -qxF "$nombre" && continue
        [ -n "$(prowlarr_ficha "$nombre")" ] || continue
        ofrecidos=$((ofrecidos+1))
    done

    if [ "$ofrecidos" -eq 0 ]; then
        gris "     los indexers recomendados ya estan cargados"
        return 0
    fi

    echo ""
    info "Prowlarr trae ${B}636${N} indexers y ninguna forma de saber cual sirve."
    info "Te ofrezco ${B}$ofrecidos${N} que valen la pena, de a uno y explicados."
    gris "     Lo que agregues se le sincroniza solo a Radarr y a Sonarr."
    echo ""

    for par in "${PROWLARR_CATALOGO[@]}"; do
        IFS='|' read -r nombre para <<< "$par"
        echo "$cargados" | grep -qxF "$nombre" && continue

        ficha=$(prowlarr_ficha "$nombre")
        [ -n "$ficha" ] || continue
        IFS='|' read -r privacy flare url claves <<< "$ficha"

        # Las etiquetas van ANTES de la descripcion, no despues: que necesite
        # una cuenta es lo primero que cambia la respuesta.
        local etiquetas=""
        case "$privacy" in
            private)     etiquetas="${A}PRIVADO · necesita cuenta${N}" ;;
            semiPrivate) etiquetas="${A}semi-privado · puede pedir cuenta${N}" ;;
            *)           etiquetas="${G}publico · no necesita cuenta${N}" ;;
        esac
        [ "$flare" = "si" ] && etiquetas="$etiquetas  ${G}·  usa FlareSolverr${N}"

        echo "  ${B}$nombre${N}   $etiquetas"
        gris "     $para"
        [ -n "$url" ] && gris "     $url"

        if ! preguntar "     ¿Lo agrego?" "n"; then echo ""; continue; fi

        # Credenciales: se piden, y si no las tenes a mano se saltea y queda
        # anotado. Nunca se inventa una cuenta ni se deja el indexer a medias
        # sin decirlo.
        local creds="" campo valor faltan=0
        if [ -n "$claves" ]; then
            echo ""
            info "     Este indexer necesita tu cuenta en el sitio."
            gris "     Registrate en $url y despues copia los datos aca."
            gris "     Si no la tenes ahora, apreta Enter en cada uno y lo salteo."
            for campo in ${claves//,/ }; do
                read -r -p "        $campo: " valor </dev/tty
                if [ -z "$valor" ]; then faltan=1; break; fi
                creds="$creds$campo=$valor;"
            done
            if [ "$faltan" = "1" ]; then
                info "     Lo salteo."
                pendiente "Agregar el indexer $nombre en http://prowlarr.pi con tu cuenta de $url"
                echo ""
                continue
            fi
        fi

        local tag=""
        [ "$flare" = "si" ] && tag=$(prowlarr_tag_flare)

        if prowlarr_agregar "$nombre" "$url" "$tag" "$creds"; then
            ok "$nombre agregado"
            [ -n "$tag" ] && gris "     con la etiqueta flaresolverr, que es la que lo hace funcionar"
            puestos=$((puestos+1))
            cargados="$cargados
$nombre"
        else
            aviso "$nombre: Prowlarr no lo acepto"
            pendiente "Agregar el indexer $nombre a mano en http://prowlarr.pi"
        fi
        echo ""
    done

    [ "$puestos" -gt 0 ] && \
        ok "$puestos $(plural "$puestos" "indexer cargado" "indexers cargados"), ya sincronizados a Radarr y Sonarr"
    return 0
}
