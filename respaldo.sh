#!/bin/bash
# ==============================================================================
#  respaldo.sh  ·  Lo que no se puede reconstruir del repo
#
#      ./respaldo.sh                  lo deja en /tmp y te dice como bajarlo
#      ./respaldo.sh /ruta/destino    lo deja donde le digas
#      ./respaldo.sh --listar         muestra que capturaria, sin hacer nada
#
#  QUE ENTRA Y QUE NO
#
#  Entra lo irrecuperable: las contrasenas y tokens de los .env, las bases de
#  datos de cada servicio, y los archivos de configuracion que se editaron a
#  mano. Todo eso junto pesa unos pocos megas.
#
#  No entra lo que se reconstruye solo: imagenes de Docker, la cache de
#  Jellyfin, el historico de Prometheus, ni nada versionado en GitHub. Meter
#  eso multiplicaria el tamano por cien y no salvaria nada que importe.
#
#  POR QUE SE ARMA EN /tmp
#
#  /tmp es tmpfs, o sea RAM. Armar el respaldo ahi no escribe un solo byte en
#  la microSD. Un respaldo que desgasta el medio que intenta proteger es un
#  mal negocio, y encima corre justo cuando el disco puede estar por llenarse.
#
#  LAS BASES SE COPIAN CON SQLITE, NO CON cp
#
#  Copiar un .db en caliente con cp puede dar un archivo roto: SQLite escribe
#  en un WAL aparte y lo une despues, asi que el archivo solo no siempre esta
#  completo. La API de respaldo de SQLite si da una copia consistente aunque
#  el servicio este escribiendo en ese momento.
#
#  UN RESPALDO QUE VIVE EN EL MISMO DISCO NO ES UN RESPALDO
#
#  El ultimo paso lo tenes que hacer vos: bajarlo a otra maquina. El script
#  te deja el comando listo al terminar.
# ==============================================================================

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO" || exit 1

V=$'\e[0;32m'; R=$'\e[0;31m'; A=$'\e[1;33m'; C=$'\e[0;36m'
G=$'\e[0;90m'; B=$'\e[1m'; N=$'\e[0m'
ok()    { echo "  ${V}✓${N} $*"; }
falla() { echo "  ${R}✗${N} $*"; }
aviso() { echo "  ${A}!${N} $*"; }
info()  { echo "    $*"; }
gris()  { echo "  ${G}$*${N}"; }

# Para poder avisar si falla. Un respaldo que se rompe en silencio es peor que
# no tenerlo, porque te deja creyendo que estas cubierto.
# shellcheck source=lib/avisos.sh
. "$REPO/lib/avisos.sh"

SOLO_LISTAR=0
DESTINO="/tmp"
ROTAR=0
CALLADO=0
AVISAR=0
for arg in "$@"; do
    case "$arg" in
        --listar|-l)  SOLO_LISTAR=1 ;;
        --callado|-q) CALLADO=1 ;;
        --avisar)     AVISAR=1 ;;
        --rotar=*)    ROTAR="${arg#--rotar=}" ;;
        --ayuda|-h)   sed -n '3,9p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)            DESTINO="$arg" ;;
    esac
done

# El exito NO notifica, a proposito: seria un mensaje por dia que no pide
# ninguna decision, y con eso el canal se vuelve ruido. Queda anotado en el
# feed, que es donde vive lo que vale la pena recordar y no interrumpe.
respaldo_termino() {
    local nivel="$1" texto="$2"
    [ "$AVISAR" = "1" ] || return 0
    avisar_si_cambio respaldo "$nivel" "respaldo" "$texto"
    [ "$nivel" = "bien" ] && evento sistema "respaldo ok · $texto"
    return 0
}

FECHA=$(date +%Y-%m-%d-%H%M)
TRABAJO="/tmp/respaldo-$FECHA"
ARCHIVO="$DESTINO/pi-respaldo-$FECHA.tar.gz"
DOCKER="sudo docker"

echo ""
echo "${B}${C}  Respaldo de Pi-Services${N}"
gris "  Se arma en RAM para no escribir en la tarjeta."
echo ""

# ── Copia consistente de una base SQLite ──────────────────────────────────────
copiar_base() {
    local origen="$1" destino="$2"
    mkdir -p "$(dirname "$destino")"
    ORIGEN="$origen" DESTINO="$destino" python3 - <<'PY' 2>/dev/null
import os, sqlite3, shutil, sys
o, d = os.environ["ORIGEN"], os.environ["DESTINO"]
try:
    con = sqlite3.connect("file:" + o + "?mode=ro", uri=True)
    dst = sqlite3.connect(d)
    con.backup(dst)          # consistente aunque el servicio este escribiendo
    dst.close(); con.close()
except Exception:
    # Si no es SQLite o esta cerrada de una forma rara, mejor una copia cruda
    # que nada: se avisa en el manifiesto que puede no estar consistente.
    try:
        shutil.copy2(o, d)
    except Exception:
        sys.exit(1)
PY
}

# ── Que hay para respaldar ────────────────────────────────────────────────────
listar_envs()   { find "$REPO" -name ".env" -not -path "*/node_modules/*" 2>/dev/null | sort; }
listar_tokens() { find "$REPO" -name "token*.json" -not -path "*/node_modules/*" 2>/dev/null | sort; }
# No alcanza con *.db. Wallabag llama a la suya wallabag.sqlite y FreshRSS usa
# db.sqlite: buscando solo .db quedaban afuera, y eso se descubre el dia que
# hacen falta. Un respaldo que se saltea archivos en silencio es peor que no
# tenerlo, porque da la sensacion de estar cubierto.
listar_bases_repo() {
    find "$REPO" \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" -o -name "*.db3" \) \
        -not -path "*/node_modules/*" 2>/dev/null | sort
}

listar_bases_volumenes() {
    # Solo las bases de configuracion. Se excluyen los logs, que son ruido, y
    # el historico de Prometheus, que pesa y se reconstruye solo.
    sudo find /var/lib/docker/volumes \
        \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" -o -name "*.db3" \) \
        -size +0 2>/dev/null \
        | grep -v "/logs.db$" | grep -v "prometheus" | grep -v "\.corrupta$" | sort
}

listar_config() {
    local f
    for f in "$REPO/caddy/Caddyfile" \
             "$REPO/news/news-filter/config/keywords.txt" \
             "$REPO/monitoring/prometheus.yml" \
             "$REPO/homepage/config/services.yaml"; do
        [ -f "$f" ] && echo "$f"
    done
    $DOCKER exec bazarr sh -c 'test -f /config/config/config.yaml' 2>/dev/null && echo "docker:bazarr:/config/config/config.yaml"
    return 0
}

# La historia propia: el feed de eventos y el estado de los avisos.
#
# No es configuracion y no es una base, pero tampoco se reconstruye de ningun
# lado: son meses de "que paso y cuando", y el estado de los avisos es lo que
# evita que despues de restaurar te lleguen de golpe treinta notificaciones de
# cosas que ya sabias. Todo junto pesa unos 100 KB.
listar_historia() {
    local f
    for f in "$REPO/datos/eventos.log" \
             "$REPO/datos/estado-avisos" \
             "$REPO/datos/metricas-lentas.prom"; do
        [ -f "$f" ] && echo "$f"
    done
    return 0
}

if [ "$SOLO_LISTAR" = "1" ]; then
    echo "${B}  Variables y contrasenas${N}"
    listar_envs | sed "s|$REPO/|    |"
    echo ""
    echo "${B}  Tokens${N}"
    listar_tokens | sed "s|$REPO/|    |" || true
    echo ""
    echo "${B}  Bases de datos${N}"
    listar_bases_repo | sed "s|$REPO/|    |"
    listar_bases_volumenes | sed "s|/var/lib/docker/volumes/|    |"
    echo ""
    echo "${B}  Configuracion editada a mano${N}"
    listar_config | sed "s|$REPO/|    |"
    echo ""
    echo "${B}  Historia propia${N}"
    listar_historia | sed "s|$REPO/|    |"
    echo ""
    exit 0
fi

# ── Armado ────────────────────────────────────────────────────────────────────
rm -rf "$TRABAJO"
mkdir -p "$TRABAJO"/{env,tokens,db,config,historia}

n_env=0; n_tok=0; n_db=0; n_cfg=0; n_hist=0; fallos=0

for f in $(listar_envs); do
    rel="${f#"$REPO"/}"
    mkdir -p "$TRABAJO/env/$(dirname "$rel")"
    cp "$f" "$TRABAJO/env/$rel" 2>/dev/null && n_env=$((n_env+1))
done

for f in $(listar_tokens); do
    rel="${f#"$REPO"/}"
    mkdir -p "$TRABAJO/tokens/$(dirname "$rel")"
    cp "$f" "$TRABAJO/tokens/$rel" 2>/dev/null && n_tok=$((n_tok+1))
done

for f in $(listar_bases_repo); do
    rel="${f#"$REPO"/}"
    copiar_base "$f" "$TRABAJO/db/repo/$rel" && n_db=$((n_db+1)) || fallos=$((fallos+1))
done

for f in $(listar_bases_volumenes); do
    rel="${f#/var/lib/docker/volumes/}"
    sudo cp "$f" "/tmp/.base-temporal" 2>/dev/null || { fallos=$((fallos+1)); continue; }
    sudo chown "$USER" "/tmp/.base-temporal" 2>/dev/null
    copiar_base "/tmp/.base-temporal" "$TRABAJO/db/volumenes/$rel" && n_db=$((n_db+1)) || fallos=$((fallos+1))
    rm -f "/tmp/.base-temporal"
done

for f in $(listar_config); do
    if [[ "$f" == docker:* ]]; then
        cont="${f#docker:}"; cont="${cont%%:*}"
        ruta="${f##*:}"
        mkdir -p "$TRABAJO/config/$cont"
        $DOCKER exec "$cont" cat "$ruta" > "$TRABAJO/config/$cont/$(basename "$ruta")" 2>/dev/null && n_cfg=$((n_cfg+1))
    else
        rel="${f#"$REPO"/}"
        mkdir -p "$TRABAJO/config/$(dirname "$rel")"
        cp "$f" "$TRABAJO/config/$rel" 2>/dev/null && n_cfg=$((n_cfg+1))
    fi
done

for f in $(listar_historia); do
    cp "$f" "$TRABAJO/historia/$(basename "$f")" 2>/dev/null && n_hist=$((n_hist+1))
done

# ── Manifiesto: sin esto, dentro de seis meses el tar es un misterio ──────────
cat > "$TRABAJO/MANIFIESTO.txt" <<EOF
Respaldo de Pi-Services
Fecha:   $(date '+%Y-%m-%d %H:%M:%S %Z')
Equipo:  $(hostname)  ·  $(uname -srm)

Contenido
  env/         $n_env archivos .env, con contrasenas y claves de API
  tokens/      $n_tok tokens de OAuth (Fitbit, Microsoft)
  db/          $n_db bases de datos, copiadas con la API de SQLite
  config/      $n_cfg archivos de configuracion editados a mano
  historia/    $n_hist archivos: el feed de eventos y el estado de los avisos

Lo que NO esta, porque se reconstruye del repo o solo:
  imagenes de Docker, cache de Jellyfin, historico de Prometheus,
  y todo lo que ya esta versionado en GitHub.

Como se restaura
  1. Cloná el repo:            git clone <url> ~/pi-services
  2. Descomprimí este archivo: tar xzf pi-respaldo-*.tar.gz
  3. Copiá los .env:           cp -r env/* ~/pi-services/
  4. Copiá los tokens:         cp -r tokens/* ~/pi-services/
  5. Las bases de repo:        cp -r db/repo/* ~/pi-services/
  6. La historia:              mkdir -p ~/pi-services/datos && cp historia/* ~/pi-services/datos/
  7. Levantá:                  cd ~/pi-services && ./instalador.sh
  8. Las bases de volumenes van adentro de cada volumen de Docker, con el
     contenedor PARADO. Ejemplo, para Radarr:
       docker stop radarr
       docker run --rm -v pi-services_radarr-config:/c -v \$PWD/db/volumenes:/b \\
         alpine cp /b/pi-services_radarr-config/_data/radarr.db /c/radarr.db
       docker start radarr

Verificacion
  Este respaldo se probo leyendo el tar despues de crearlo. Que se pueda leer
  no garantiza que restaure bien: la unica prueba de verdad es restaurarlo.
EOF

# ── Empaquetado ───────────────────────────────────────────────────────────────
mkdir -p "$DESTINO"
tar czf "$ARCHIVO" -C "$TRABAJO" . 2>/dev/null

if [ ! -s "$ARCHIVO" ]; then
    falla "No se pudo crear el archivo"
    respaldo_termino mal "no se pudo crear el archivo en $DESTINO"
    rm -rf "$TRABAJO"
    exit 1
fi

# Un respaldo sin verificar es una suposicion
entradas=$(tar tzf "$ARCHIVO" 2>/dev/null | wc -l)
if [ "$entradas" -lt 5 ]; then
    falla "El archivo se creo pero casi no tiene nada adentro ($entradas entradas)"
    respaldo_termino mal "el archivo salio casi vacio ($entradas entradas)"
    rm -rf "$TRABAJO"
    exit 1
fi

rm -rf "$TRABAJO"
tamano=$(du -h "$ARCHIVO" | cut -f1)

# Rotacion, para que la copia automatica no crezca sin techo
if [ "$ROTAR" -gt 0 ] 2>/dev/null; then
    viejos=$(ls -1t "$DESTINO"/pi-respaldo-*.tar.gz 2>/dev/null | tail -n +$((ROTAR+1)))
    if [ -n "$viejos" ]; then
        echo "$viejos" | xargs rm -f
        [ "$CALLADO" = "1" ] || gris "  Borre $(echo "$viejos" | wc -l) respaldos viejos, quedan los ultimos $ROTAR"
    fi
fi

if [ "$fallos" -gt 0 ]; then
    respaldo_termino ojo "$tamano, pero $fallos archivos no se pudieron copiar"
else
    respaldo_termino bien "$tamano, $entradas entradas"
fi

if [ "$CALLADO" = "1" ]; then
    echo "$(date '+%F %T')  $ARCHIVO  $tamano  $entradas entradas  $fallos fallos"
    exit 0
fi

ok "$n_env .env  ·  $n_tok tokens  ·  $n_db bases  ·  $n_cfg configuraciones  ·  $n_hist de historia"
[ "$fallos" -gt 0 ] && aviso "$fallos archivos no se pudieron copiar"
ok "Listo: ${B}$ARCHIVO${N}  ($tamano, $entradas entradas, verificado)"

echo ""
echo "  ${A}${B}Falta el paso que importa.${N}"
info "Esto todavia vive en la misma tarjeta que intenta proteger."
info "Bajalo a tu PC, desde tu PC:"
echo ""
echo "    scp jlussich@$(hostname -I | awk '{print $1}'):$ARCHIVO ."
echo ""
gris "  Si el destino es /tmp, se borra al reiniciar. Es a proposito: obliga a"
gris "  bajarlo, en vez de dejar una copia falsa en el mismo disco."
echo ""
