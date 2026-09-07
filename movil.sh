#!/bin/bash
# ==============================================================================
#  movil.sh  ·  Las apps del celular, con los datos para configurarlas
#
#      ./movil.sh           te va preguntando de a una, como en el instalador
#      ./movil.sh --todo    todos los datos de una, sin preguntar
#
#  El instalador ofrece esto mismo al terminar. Este script existe para volver
#  a verlo despues: cuando cambies de telefono, cuando agregues un servicio, o
#  cuando simplemente no te acuerdes de la direccion.
#
#  Lo que sale de aca son claves de API, que valen tanto como una contrasena.
#  Se leen del servidor en el momento y no quedan escritas en ningun lado.
# ==============================================================================

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO" || exit 1

# comun.sh trae los helpers y, de paso, carga lib/movil.sh
# shellcheck source=lib/comun.sh
source "$REPO/lib/comun.sh"

todo() {
    local app clave nombre plataforma para hubo=0
    for app in "${MOVIL_APPS[@]}"; do
        IFS='|' read -r clave nombre plataforma para <<< "$app"
        movil_aplica "$clave" || continue
        hubo=1
        echo ""
        echo "  ${B}${C}$nombre${N}  ${G}·  $plataforma${N}"
        gris "     $para"
        echo ""
        movil_datos "$clave"
    done
    [ "$hubo" = "1" ] || info "Todavia no hay nada corriendo que se use desde el celular."
    echo ""
}

case "${1:-}" in
    --todo|-t)
        echo ""
        echo "${B}${C}━━━ Las apps del celular ━━━${N}"
        todo
        ;;
    -h|--help)
        sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    "")
        echo ""
        echo "${B}${C}━━━ Las apps del celular ━━━${N}"
        configurar_movil
        ;;
    *)
        echo "  No conozco la opcion '$1'. Proba  ./movil.sh --help"
        exit 1
        ;;
esac
