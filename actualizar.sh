#!/bin/bash
# ==============================================================================
#  actualizar.sh  ·  Que hay de nuevo, y actualizar lo que elijas
#
#      ./actualizar.sh          revisa y te ofrece actualizar de a uno
#      ./actualizar.sh --ver    solo revisa y te dice, sin tocar nada
#
#  Casi todas las imagenes estan en :latest o :stable, que suena a que no hay
#  nada que decidir y es al reves: se actualizan solas, sin avisar, la proxima
#  vez que alguien recree un contenedor por cualquier otro motivo.
#
#  Esto lo da vuelta: mira que hay de nuevo antes de tocar nada, te dice de que
#  version a que version y donde leer los cambios, y actualiza lo que elijas.
# ==============================================================================

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO" || exit 1

# shellcheck source=lib/comun.sh
source "$REPO/lib/comun.sh"

case "${1:-}" in
    --ver|-v)
        echo ""
        echo "${B}${C}━━━ Que hay de nuevo ━━━${N}"
        echo ""
        info "Comparo lo que tenes contra lo publicado, sin bajar ni tocar nada."
        echo ""
        act_revisar
        if [ "${#ACT_NOVEDADES[@]}" -eq 0 ]; then
            ok "Todo al dia"
        else
            info "Hay ${B}${#ACT_NOVEDADES[@]}${N} con version nueva:"
            echo ""
            for l in "${ACT_NOVEDADES[@]}"; do
                IFS='|' read -r c img ver url <<< "$l"
                act_linea "$c" "$ver" "$url"
            done
            echo ""
            gris "     Para actualizar:  ${B}pi actualizar${N}"
        fi
        echo ""
        ;;
    -h|--help)
        sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    "")
        actualizar_servicios
        ;;
    *)
        echo "  No conozco la opcion '$1'. Proba  ./actualizar.sh --help"
        exit 1
        ;;
esac
