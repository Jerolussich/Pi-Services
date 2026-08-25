#!/bin/bash
# ==============================================================================
#  avisos.sh  ·  El feed de eventos y los avisos al celular
#
#      ./avisos.sh              las ultimas lineas del feed
#      ./avisos.sh --todo       el feed entero
#      ./avisos.sh --canales    a que suscribirte en la app, paso a paso
#      ./avisos.sh --probar     manda un aviso de prueba a los dos canales
#      ./avisos.sh --prender    vuelve a mandar avisos al celular
#      ./avisos.sh --apagar     deja de mandarlos, sin borrar los canales
#      ./avisos.sh --media      manda la tanda de importaciones, si toca
#
#  COMO LLEGAN LOS AVISOS
#
#  Por ntfy, que es un canal de radio: eligis un nombre, la Pi transmite ahi y
#  tu celular esta sintonizado. Sin cuenta, sin token, sin servidor propio. El
#  nombre del canal ES la contrasena, por eso lo genera el instalador al azar
#  y vive en el .env, que nunca se versiona.
#
#  SON DOS CANALES Y NO UNO
#
#      alertas   lo que se rompe. Suena. Casi nunca habla.
#      media     lo que esta listo. Silencioso y agrupado.
#
#  Van separados para que puedas silenciar el segundo sin quedarte ciego al
#  primero, y para que el de alertas conserve su propiedad mas importante:
#  que si no suena, esta todo bien.
#
#  Documentacion:  docs/AVISOS.md
# ==============================================================================

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO" || exit 1

# shellcheck source=lib/avisos.sh
. "$REPO/lib/avisos.sh"

ok()    { echo "  ${V}✓${N} $*"; }
falla() { echo "  ${R}✗${N} $*"; }
info()  { echo "    $*"; }
gris()  { echo "  ${G}$*${N}"; }
titulo(){ echo ""; echo "${B}${C}━━━ $* ━━━${N}"; echo ""; }

# ══════════════════════════════════════════════════════════════════════════════
#  EL FEED
# ══════════════════════════════════════════════════════════════════════════════

mostrar_feed() {
    local cuantas="${1:-30}"
    if [ ! -s "$FEED" ]; then
        titulo "Feed de eventos"
        info "Todavia no hay nada anotado."
        gris "     Se llena solo: el diagnostico cada hora, el respaldo a las 04:00,"
        gris "     y las importaciones de Radarr y Sonarr cuando pasen."
        echo ""
        return 0
    fi

    titulo "Ultimos eventos"
    local fecha origen texto color
    while IFS=$'\t' read -r fecha origen texto; do
        case "$origen" in
            alerta)  color="$A" ;;
            media)   color="$C" ;;
            discos)  color="$B" ;;
            *)       color="$G" ;;
        esac
        printf "  ${G}%s${N}  ${color}%-8s${N} %s\n" "$fecha" "$origen" "$texto"
    done < <(tail -n "$cuantas" "$FEED")
    echo ""
    gris "     $(wc -l < "$FEED" | tr -d ' ') eventos guardados  ·  tambien en http://eventos.pi"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  LOS CANALES
# ══════════════════════════════════════════════════════════════════════════════

mostrar_canales() {
    titulo "Tus canales"
    if avisos_apagados; then
        info "Los avisos estan ${B}apagados${N} porque asi lo elegiste."
        echo ""
        gris "     El diagnostico sigue corriendo igual, el feed se llena igual"
        gris "     y Grafana recibe las metricas igual. Solo no suena el celular."
        echo ""
        info "Para prenderlos:  ${B}./avisos.sh --prender${N}"
        echo ""
        return 0
    fi
    if ! avisos_configurados; then
        falla "Todavia no hay canales creados."
        info "Los crea el instalador. Corré ${B}./instalador.sh${N} y elegí el modulo"
        info "${B}Avisos${N} de la lista."
        echo ""
        return 1
    fi
    guia_suscripcion
}

# Prender y apagar. Existe porque decir que no en el instalador no puede ser
# una decision para siempre, y porque borrar los nombres para apagarlos te
# obligaria a volver a suscribirte desde cero si cambias de idea.
prender() {
    escribir_ajuste AVISOS si
    titulo "Avisos prendidos"
    if [ -z "${NTFY_ALERTAS:-}" ]; then
        info "Todavia no hay canales creados."
        info "Corré ${B}./instalador.sh${N} y elegí el modulo ${B}Avisos${N}."
        echo ""
        return 0
    fi
    AVISOS=si
    ok "Vuelven a salir por los canales de siempre."
    guia_suscripcion
}

apagar() {
    escribir_ajuste AVISOS no
    titulo "Avisos apagados"
    ok "No te va a llegar nada mas al celular."
    echo ""
    gris "     Los nombres de los canales quedan guardados, asi que si los"
    gris "     prendes de nuevo no hace falta volver a suscribirse."
    echo ""
    info "Lo que sigue funcionando igual:"
    gris "     el diagnostico cada hora, el feed en http://eventos.pi,"
    gris "     las metricas de Grafana y el mensaje de bienvenida del SSH."
    echo ""
    info "Para volver a prenderlos:  ${B}./avisos.sh --prender${N}"
    echo ""
    # El envio agrupado de media no tiene sentido sin canal donde mandarlo.
    sudo systemctl disable --now pi-media.timer >/dev/null 2>&1
}

escribir_ajuste() {
    local var="$1" valor="$2" tmp
    touch "$REPO/.env"
    tmp=$(mktemp)
    grep -vE "^${var}=" "$REPO/.env" > "$tmp" 2>/dev/null
    printf '%s=%s\n' "$var" "$valor" >> "$tmp"
    mv "$tmp" "$REPO/.env"
}

probar() {
    titulo "Prueba"
    if ! avisos_configurados; then
        falla "No hay canales configurados todavia."
        info "Corre el instalador y volve a probar."
        return 1
    fi
    info "Mandando uno a cada canal..."
    echo ""
    # A proposito con nivel "mal": es el unico que ignora el horario de
    # silencio, asi que la prueba funciona tambien de madrugada.
    notificar mal "Prueba de Pi-Services" "Si leiste esto, el canal de alertas funciona."
    ok "alertas"
    if [ -n "${NTFY_MEDIA:-}" ]; then
        notificar info "Prueba de Pi-Services" "Este es el canal de media." media
        ok "media"
    fi
    evento sistema "prueba de avisos"
    echo ""
    info "Si no llego nada, revisa que estes suscrito a los nombres correctos:"
    gris "     ./avisos.sh --canales"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  LA TANDA DE MEDIA
#
#  Radarr y Sonarr no avisan al importar: escriben una linea en un archivo.
#  Esto corre cada pocos minutos y manda UN mensaje cuando la tanda termino.
#
#  Sin esto, un pack de temporada son ocho notificaciones seguidas. Con esto,
#  un capitulo suelto sigue siendo un aviso y un pack tambien es uno solo.
#
#  El contenedor no manda nada por si mismo a proposito: asi no necesita curl,
#  no necesita internet, y sobre todo el nombre del canal NUNCA entra a un
#  contenedor.
# ══════════════════════════════════════════════════════════════════════════════

enviar_media() {
    local archivo="$MEDIA_PENDIENTE/pendiente"
    [ -s "$archivo" ] || return 0

    # La tanda se da por cerrada cuando dejo de crecer.
    local mod edad
    mod=$(stat -c %Y "$archivo" 2>/dev/null) || return 0
    edad=$(( $(date +%s) - mod ))
    [ "$edad" -ge $(( MEDIA_ESPERA_MIN * 60 )) ] || return 0

    # Se lo lleva de una, asi lo que llegue mientras se procesa no se pierde:
    # el gancho vuelve a crear el archivo con el proximo >>.
    local trabajo="$archivo.enviando"
    mv "$archivo" "$trabajo" 2>/dev/null || return 0

    # Las mejoras de calidad se descartan aca y no en el contenedor, para que
    # la decision viva en ajustes.conf y no haya que recrear nada para cambiarla.
    if [ "${MEDIA_AVISAR_MEJORAS:-0}" != "1" ]; then
        awk -F'\t' '$4 != "True"' "$trabajo" > "$trabajo.f" 2>/dev/null && mv "$trabajo.f" "$trabajo"
    fi
    if [ ! -s "$trabajo" ]; then rm -f "$trabajo"; return 0; fi

    # ── Peliculas: una sola tanda ──
    local pelis n
    pelis=$(awk -F'\t' '$1=="pelicula" && $2!="" {print $2}' "$trabajo" | sort -u)
    n=$(printf '%s' "$pelis" | grep -c . || true)
    if [ "${n:-0}" -eq 1 ]; then
        local detalle
        detalle=$(awk -F'\t' '$1=="pelicula"{print $3; exit}' "$trabajo")
        notificar info "$pelis" "${detalle:+$detalle · }ya la podes ver" media
        evento media "$pelis importada"
    elif [ "${n:-0}" -gt 1 ]; then
        # Con paste -d', ' los separadores se alternan (coma, espacio, coma) y
        # queda "A,B C". awk une bien y no le molesta un titulo con comas.
        local listado
        listado=$(printf '%s\n' "$pelis" | awk 'NR>1{printf ", "}{printf "%s", $0}')
        notificar info "$n peliculas nuevas" "$listado" media
        evento media "$n peliculas importadas: $listado"
    fi

    # ── Series: una tanda por temporada ──
    local grupo cuantos capitulo
    while IFS= read -r grupo; do
        [ -n "$grupo" ] || continue
        cuantos=$(awk -F'\t' -v g="$grupo" '$1=="serie" && $2==g' "$trabajo" | wc -l | tr -d ' ')
        if [ "$cuantos" -eq 1 ]; then
            capitulo=$(awk -F'\t' -v g="$grupo" '$1=="serie" && $2==g {print $3; exit}' "$trabajo")
            notificar info "$grupo" "${capitulo:+$capitulo · }ya lo podes ver" media
            evento media "$grupo $capitulo importado"
        else
            notificar info "$grupo" "$cuantos episodios nuevos" media
            evento media "$grupo, $cuantos episodios importados"
        fi
    done < <(awk -F'\t' '$1=="serie" && $2!="" {print $2}' "$trabajo" | sort -u)

    rm -f "$trabajo"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════

case "${1:-}" in
    --media)         enviar_media ;;
    --canales|-c)    mostrar_canales ;;
    --probar|-p)     probar ;;
    --prender)       prender ;;
    --apagar)        apagar ;;
    --todo|-t)       mostrar_feed 100000 ;;
    --ayuda|-h)      sed -n '3,12p' "$0" | sed 's/^# \?//' ;;
    "")              mostrar_feed 30 ;;
    *)               falla "No conozco la opcion $1"; exit 1 ;;
esac
