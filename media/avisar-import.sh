#!/bin/sh
# ==============================================================================
#  media/avisar-import.sh  ·  El gancho que corre ADENTRO de Radarr y Sonarr
#
#  Radarr y Sonarr saben ejecutar un script cuando terminan de importar algo.
#  Este es ese script, y lo unico que hace es escribir una linea en un archivo
#  compartido con el host.
#
#  NO MANDA NADA. Y eso es a proposito, por tres motivos:
#
#    1. El nombre del canal de ntfy es la contrasena de tus avisos, y asi
#       NUNCA entra a un contenedor.
#    2. No necesita curl, ni internet, ni saber que existe ntfy.
#    3. Un pack de temporada dispara este script ocho veces seguidas. Mandar
#       de una serian ocho notificaciones; escribir ocho lineas deja que el
#       host las agrupe en un solo aviso.
#
#  Quien lee esas lineas y avisa es avisos.sh --media, en el host.
#
#  FORMATO DE CADA LINEA
#
#      tipo <TAB> agrupador <TAB> detalle
#
#  El agrupador es lo que se junta en un solo mensaje: la pelicula sola, o la
#  serie y su temporada.
# ==============================================================================

SALIDA="/avisos/pendiente"

# Radarr y Sonarr disparan esto tambien cuando apretas "Test" en su pantalla
# de configuracion. Tiene que salir bien, o el boton reporta error y parece
# que el gancho esta roto cuando esta perfecto.
case "${radarr_eventtype:-}${sonarr_eventtype:-}" in
    Test) exit 0 ;;
esac

# Solo importaciones. Grab, Rename, Health y las demas no son novedades.
case "${radarr_eventtype:-}${sonarr_eventtype:-}" in
    Download) ;;
    *) exit 0 ;;
esac

# Que te reemplacen un 720p por un 1080p de algo que ya tenias no es una
# novedad, es ruido, y el perfil de calidad que mejora solo lo dispara seguido.
# El host decide si los quiere: aca se marcan y alla se filtran.
MEJORA="${radarr_isupgrade:-${sonarr_isupgrade:-False}}"

[ -d /avisos ] || exit 0

if [ -n "${radarr_movie_title:-}" ]; then
    TITULO="$radarr_movie_title"
    [ -n "${radarr_movie_year:-}" ] && TITULO="$TITULO ($radarr_movie_year)"
    printf 'pelicula\t%s\t%s\t%s\n' \
        "$TITULO" "${radarr_moviefile_quality:-}" "$MEJORA" >> "$SALIDA"
    exit 0
fi

if [ -n "${sonarr_series_title:-}" ]; then
    TEMPORADA="${sonarr_episodefile_seasonnumber:-0}"
    GRUPO="$(printf '%s · temporada %s' "$sonarr_series_title" "$TEMPORADA")"
    # S02E03, que es como lo nombra todo el mundo. El numero de episodio puede
    # venir como lista (3,4) cuando un archivo trae dos capitulos.
    CAPITULO="$(printf 'S%02dE%s' "$TEMPORADA" "${sonarr_episodefile_episodenumbers:-?}" 2>/dev/null)"
    printf 'serie\t%s\t%s\t%s\n' "$GRUPO" "$CAPITULO" "$MEJORA" >> "$SALIDA"
    exit 0
fi

exit 0
