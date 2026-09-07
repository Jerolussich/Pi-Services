# ==============================================================================
#  ACTUALIZAR LOS CONTENEDORES
#
#  Casi todas las imagenes estan clavadas en :latest o :stable, que suena a que
#  no hay nada que decidir y es exactamente al reves: significa que se actualizan
#  solas, sin avisar, en el momento en que a alguien se le ocurre recrear un
#  contenedor por cualquier otro motivo.
#
#  Eso ya paso aca. El compose de Home Assistant decia 2026.6.4 y el contenedor
#  corria 2026.9.1, porque en algun momento se levanto con :stable. El archivo
#  quedo mintiendo y el proximo "docker compose up -d" de rutina iba a BAJAR
#  Home Assistant tres meses sobre datos escritos por la version nueva.
#
#  Asi que se da vuelta el asunto: se mira que hay de nuevo ANTES de tocar nada,
#  se te dice de que version a que version, con el link a la lista de cambios, y
#  actualiza lo que vos elijas.
#
#  ── Como se sabe que hay algo nuevo ──────────────────────────────────────────
#
#  Comparando la huella de la imagen que tenes contra la que hay publicada, sin
#  descargar nada. No alcanza con mirar la etiqueta: :latest de hace seis meses
#  y :latest de hoy se llaman igual y son cosas distintas. La huella no miente.
# ==============================================================================

# ── Datos de una imagen ───────────────────────────────────────────────────────

act_imagen_de()  { $DOCKER inspect "$1" --format '{{.Config.Image}}' 2>/dev/null; }

act_version_de() {
    $DOCKER image inspect "$1" \
        --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null \
        | grep -v '^<no value>$'
}

# De donde salio la imagen, para poder mandarte a la lista de cambios
act_fuente_de() {
    $DOCKER image inspect "$1" \
        --format '{{index .Config.Labels "org.opencontainers.image.source"}}' 2>/dev/null \
        | grep -v '^<no value>$'
}

act_digest_local() {
    $DOCKER image inspect "$1" --format '{{range .RepoDigests}}{{.}}{{println}}{{end}}' 2>/dev/null \
        | head -1 | sed 's/.*@//'
}

# La huella publicada, sin bajar la imagen.
act_digest_remoto() {
    timeout 45 $DOCKER manifest inspect --verbose "$1" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    if isinstance(d, list): d = d[0]
    print(d.get("Descriptor", {}).get("digest", ""))
except Exception:
    pass' 2>/dev/null
}

# Las notas de la version, deducidas de donde vive el proyecto. No se inventa:
# si la imagen no dice de donde salio, no se muestra ningun link.
act_changelog() {
    local fuente="$1"
    case "$fuente" in
        https://github.com/*) echo "${fuente%.git}/releases" ;;
        *) echo "" ;;
    esac
}

# ── Revisar todo ──────────────────────────────────────────────────────────────
#
#  Deja en ACT_NOVEDADES una linea por servicio con algo nuevo:
#      contenedor|imagen|version que tenes|link a los cambios
declare -a ACT_NOVEDADES=()
declare -a ACT_SIN_REGISTRO=()

act_revisar() {
    local c img dl dr ver fuente n=0 total
    ACT_NOVEDADES=(); ACT_SIN_REGISTRO=()

    local contenedores; contenedores=$($DOCKER ps --format '{{.Names}}' 2>/dev/null | sort)
    total=$(echo "$contenedores" | grep -c . )

    for c in $contenedores; do
        n=$((n+1))
        printf "\r  ${G}revisando %s de %s: %-22s${N}" "$n" "$total" "$c" >&2

        img=$(act_imagen_de "$c")
        [ -n "$img" ] || continue

        dl=$(act_digest_local "$img")
        # Sin huella local es una imagen construida aca, no bajada de ningun
        # registro. No hay con que compararla y no es un error.
        if [ -z "$dl" ]; then
            ACT_SIN_REGISTRO+=("$c")
            continue
        fi

        dr=$(act_digest_remoto "$img")
        [ -n "$dr" ] || { ACT_SIN_REGISTRO+=("$c"); continue; }

        if [ "$dl" != "$dr" ]; then
            ver=$(act_version_de "$img")
            fuente=$(act_fuente_de "$img")
            ACT_NOVEDADES+=("$c|$img|${ver:-sin version}|$(act_changelog "$fuente")")
        fi
    done
    printf "\r%-70s\r" "" >&2
}

# Como se anuncia un servicio con novedad. Vive en una funcion porque se usa
# igual en el listado y en ./actualizar.sh --ver, y dos copias de un texto
# terminan diciendo cosas distintas.
act_linea() {
    local c="$1" ver="$2" url="$3"
    if [ -z "$ver" ] || [ "$ver" = "sin version" ]; then
        # Varias imagenes no declaran su version. Que no la digan no significa
        # que no haya cambiado: la huella ya nos dijo que si.
        echo "  ${B}$c${N}  ${G}hay una imagen mas nueva${N}"
    else
        echo "  ${B}$c${N}  ${G}tenes la $ver${N}"
    fi
    [ -n "$url" ] && gris "     que cambio:  $url"
    return 0
}

# ── El recorrido ──────────────────────────────────────────────────────────────

actualizar_servicios() {
    local linea c img ver url puestos=0 fallaron=0 verpost

    echo ""
    echo "  ${B}${C}Que hay de nuevo${N}"
    echo ""
    info "Comparo lo que tenes contra lo que hay publicado, sin bajar nada."
    gris "     Tarda un rato: hay que preguntarle a cada registro."
    echo ""

    act_revisar

    if [ "${#ACT_SIN_REGISTRO[@]}" -gt 0 ]; then
        gris "     ${#ACT_SIN_REGISTRO[@]} $(plural "${#ACT_SIN_REGISTRO[@]}" "servicio se construye aca" "servicios se construyen aca") y no se comparan"
    fi

    if [ "${#ACT_NOVEDADES[@]}" -eq 0 ]; then
        ok "Todo al dia"
        echo ""
        return 0
    fi

    echo ""
    info "Hay ${B}${#ACT_NOVEDADES[@]}${N} $(plural "${#ACT_NOVEDADES[@]}" "servicio con version nueva" "servicios con version nueva"):"
    echo ""

    for linea in "${ACT_NOVEDADES[@]}"; do
        IFS='|' read -r c img ver url <<< "$linea"
        act_linea "$c" "$ver" "$url"
    done
    echo ""

    aviso "Actualizar puede romper algo, y volver atras no siempre se puede."
    gris "     Las bases de datos de varios servicios se migran al arrancar la"
    gris "     version nueva, y hacia atras no migran. Mira los cambios antes."
    echo ""

    for linea in "${ACT_NOVEDADES[@]}"; do
        IFS='|' read -r c img ver url <<< "$linea"

        preguntar "  ¿Actualizo ${B}$c${N}?" "n" || continue

        info "  Bajando..."
        if ! $DOCKER compose pull "$c" >/dev/null 2>&1; then
            aviso "  $c: no pude bajar la imagen nueva"
            fallaron=$((fallaron+1))
            continue
        fi

        $DOCKER compose up -d "$c" >/dev/null 2>&1
        sleep 3

        if esta_arriba "$c"; then
            verpost=$(act_version_de "$(act_imagen_de "$c")")
            if [ -n "$verpost" ] && [ "$verpost" != "$ver" ]; then
                ok "  $c: de la ${B}$ver${N} a la ${B}$verpost${N}"
            else
                ok "  $c actualizado"
            fi
            puestos=$((puestos+1))
        else
            falla "  $c no volvio a levantar con la version nueva"
            gris "     los logs:  docker logs $c"
            pendiente "Revisar $c despues de actualizarlo, no levanto"
            fallaron=$((fallaron+1))
        fi
        echo ""
    done

    [ "$puestos" -gt 0 ]  && ok "$puestos $(plural "$puestos" "servicio actualizado" "servicios actualizados")"
    [ "$fallaron" -gt 0 ] && aviso "$fallaron $(plural "$fallaron" "quedo con problemas" "quedaron con problemas")"
    echo ""
    return 0
}
