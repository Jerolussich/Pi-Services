#!/bin/bash
# ==============================================================================
#  lib/avisos.sh  ·  Las cuatro salidas de un hallazgo
#
#  No se ejecuta solo: se carga con source desde diagnostico.sh, respaldo.sh,
#  avisos.sh y lib/comun.sh.
#
#  UN MOTOR, CUATRO CANILLAS
#
#  El diagnostico ya sabe que es "estar bien". Lo que le faltaba era que ese
#  saber saliera de la casa: hoy muere en un archivo que solo ves por SSH.
#
#      un hallazgo  ──▶  pantalla   (el diagnostico, como siempre)
#                   ──▶  ntfy       (solo si CAMBIO)
#                   ──▶  feed       (siempre, es la memoria)
#                   ──▶  metrica    (para Grafana, via node-exporter)
#
#  Un punto de llamada, cuatro salidas. Agregar un chequeo nuevo no obliga a
#  acordarse de las otras tres.
#
#  POR QUE ES UN ARCHIVO APARTE DE comun.sh
#
#  comun.sh son 2600 lineas que solo le sirven al instalador y al diagnostico.
#  respaldo.sh y el envio de media necesitan avisar y nada mas, asi que esto
#  tiene que poder cargarse solo. Por eso no depende de comun.sh: trae sus
#  propios helpers minimos aunque haya alguno parecido alla.
#
#  POR QUE NO ES UN CONTENEDOR
#
#  El que avisa que algo se rompio no puede romperse junto con eso. Si esto
#  fuera un contenedor, el dia que se cae Docker o se llena el disco no te
#  enterarias justamente de eso. Es el mismo criterio por el que Pi-hole y
#  Tailscale estan fuera de Docker.
#
#  Documentacion:  docs/AVISOS.md
# ==============================================================================

# Puede venir ya definido por comun.sh, que hace cd a la raiz antes.
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Colores, solo si nadie los definio antes.
: "${V:=$'\e[0;32m'}"; : "${R:=$'\e[0;31m'}"; : "${A:=$'\e[1;33m'}"
: "${C:=$'\e[0;36m'}"; : "${G:=$'\e[0;90m'}"; : "${B:=$'\e[1m'}"; : "${N:=$'\e[0m'}"

# ══════════════════════════════════════════════════════════════════════════════
#  DONDE VIVE CADA COSA
#
#  El estado y el feed van al DISCO y no a /run, aunque /run sea RAM y no
#  desgaste la tarjeta. El motivo es distinto para cada uno:
#
#    el estado  porque si se borrara al reiniciar, cada arranque dispararia
#               una rafaga de avisos de cosas que ya sabias
#    el feed    porque un feed que se olvida de todo al reiniciar no es un feed
#
#  Las metricas SI van a /run: se reescriben enteras cada hora y no tienen
#  nada que recordar.
# ══════════════════════════════════════════════════════════════════════════════

DATOS="$REPO/datos"
ESTADO_AVISOS="$DATOS/estado-avisos"
FEED="$DATOS/eventos.log"
MEDIA_PENDIENTE="$DATOS/media-pendiente"

METRICAS_DIR="/run/pi-services/metrics"
METRICAS_ARCHIVO="$METRICAS_DIR/pi.prom"

# ══════════════════════════════════════════════════════════════════════════════
#  AJUSTES
# ══════════════════════════════════════════════════════════════════════════════

# Valores por defecto. Estan aca y no solo en ajustes.conf para que el dia que
# alguien borre o rompa ese archivo, esto siga funcionando con criterio en vez
# de comparar contra variables vacias y no avisar de nada.
#
# shellcheck disable=SC2034  # los usa quien carga este archivo, no este archivo
DIAGNOSTICO_CADA=1h; HORA_RESPALDO=4; MEDIA_CADA_MIN=5
CADA_CUANTO_DISCOS=48; HORA_DISCOS=4
CADA_CUANTO_BIBLIOTECA=48; HORA_BIBLIOTECA=5
SILENCIO_DESDE=0; SILENCIO_HASTA=8; RECORDAR_CADA_HORAS=24
MEDIA_ESPERA_MIN=3; MEDIA_AVISAR_MEJORAS=0
FEED_LINEAS=1000
DISCO_OJO=75; DISCO_MAL=90; TEMP_OJO=80
DAS_OJO=85; DAS_MAL=95; DISCO_TEMP_OJO=50
HUERFANOS_GB=50; HUERFANOS_DIAS=7
PING_DESTINO=1.1.1.1; PING_PAQUETES=10; LATENCIA_OJO=150; PERDIDA_OJO=5
NTFY_SERVIDOR="https://ntfy.sh"

# shellcheck source=/dev/null
[ -f "$REPO/ajustes.conf" ] && . "$REPO/ajustes.conf"

# ══════════════════════════════════════════════════════════════════════════════
#  HELPERS MINIMOS
#
#  Deliberadamente duplicados de comun.sh: este archivo tiene que poder
#  cargarse solo desde respaldo.sh, que no conoce comun.sh.
# ══════════════════════════════════════════════════════════════════════════════

_av_leer() {
    local archivo="$1" var="$2"
    [ -f "$archivo" ] || return 1
    grep -E "^${var}=" "$archivo" 2>/dev/null | head -1 | cut -d= -f2-
}

_av_escribir() {
    local archivo="$1" var="$2" valor="$3" tmp
    mkdir -p "$(dirname "$archivo")" 2>/dev/null
    touch "$archivo" 2>/dev/null || return 1
    tmp=$(mktemp) || return 1
    grep -vE "^${var}=" "$archivo" > "$tmp" 2>/dev/null
    printf '%s=%s\n' "$var" "$valor" >> "$tmp"
    mv "$tmp" "$archivo"
}

# Los nombres de los canales viven en el .env de la raiz, que nunca se
# versiona. El nombre del canal ES la contrasena: quien lo sabe, escucha.
NTFY_ALERTAS="$(_av_leer "$REPO/.env" NTFY_ALERTAS || true)"
NTFY_MEDIA="$(_av_leer "$REPO/.env" NTFY_MEDIA || true)"

avisos_configurados() { [ -n "${NTFY_ALERTAS:-}" ]; }

# ══════════════════════════════════════════════════════════════════════════════
#  CANILLA 1  ·  NTFY
# ══════════════════════════════════════════════════════════════════════════════

# notificar <nivel> <titulo> [texto] [canal]
#
#   nivel   mal | ojo | bien
#   canal   alertas (por defecto) | media
#
# Nunca falla hacia afuera: si no hay canal configurado, si no hay internet o
# si ntfy no contesta, devuelve 0 igual. Un aviso que no sale no puede tirar
# abajo el respaldo ni el diagnostico que lo estaba llamando.
notificar() {
    local nivel="$1" titulo="$2" texto="${3:-}" canal="${4:-alertas}" tema
    case "$canal" in
        media) tema="${NTFY_MEDIA:-}" ;;
        *)     tema="${NTFY_ALERTAS:-}" ;;
    esac
    [ -n "$tema" ] || return 0
    command -v curl >/dev/null 2>&1 || return 0

    # Prioridad 5 suena y vibra. 2 llega en silencio y la ves cuando agarras
    # el telefono. No se usa 1: en Android ni siquiera aparece en la bandeja.
    local prio=2 tags="warning"
    case "$nivel" in
        mal)  prio=5; tags="rotating_light" ;;
        bien) prio=2; tags="white_check_mark" ;;
        info) prio=2; tags="clapper" ;;
    esac

    # De noche solo pasa lo grave. Las alertas menores esperan a la manana;
    # los avisos de media ya son silenciosos y no molestan a nadie.
    if [ "$nivel" != "mal" ] && [ "$canal" = "alertas" ] \
       && [ "$SILENCIO_DESDE" != "$SILENCIO_HASTA" ]; then
        # Los dos iguales significa sin horario de silencio. Sin este caso,
        # poner 0 y 0 para desactivarlo silenciaria las 24 horas, que es lo
        # contrario de lo que uno quiso.
        local hora; hora=$(date +%-H)
        if [ "$SILENCIO_DESDE" -lt "$SILENCIO_HASTA" ]; then
            [ "$hora" -ge "$SILENCIO_DESDE" ] && [ "$hora" -lt "$SILENCIO_HASTA" ] && return 0
        else
            # Ventana que cruza la medianoche, por ejemplo de 22 a 8
            { [ "$hora" -ge "$SILENCIO_DESDE" ] || [ "$hora" -lt "$SILENCIO_HASTA" ]; } && return 0
        fi
    fi

    curl -sS -m 10 -o /dev/null \
        -H "Title: $titulo" \
        -H "Priority: $prio" \
        -H "Tags: $tags" \
        -d "$texto" \
        "$NTFY_SERVIDOR/$tema" 2>/dev/null || true
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  EL ANTI SPAM: AVISAR POR TRANSICION, NO POR ESTADO
#
#  Un canal que te repite lo mismo cada hora lo silencias en una semana, y ahi
#  volviste a no tener canal. Asi que se avisa cuando algo CAMBIA:
#
#    estaba bien y se rompio   ──▶  avisa
#    sigue roto igual          ──▶  silencio
#    se arreglo                ──▶  avisa, con el tilde verde
#
#  El aviso de resuelto no es un adorno: sin el nunca aprendes a confiar en
#  que el silencio significa que esta todo bien.
#
#  Y como el estado queda guardado, sale gratis una comparacion con la corrida
#  anterior que el diagnostico solo no podia hacer: saber si un contador
#  CRECIO. Un disco con 8 sectores reasignados hace dos anos esta sano; uno
#  que paso de 0 a 8 esta semana se esta muriendo.
# ══════════════════════════════════════════════════════════════════════════════

# avisar_si_cambio <clave> <nivel> <titulo> [texto] [confirmar]
#
# El estado se guarda como  nivel|momento|anunciado
#
#   anunciado = 0  lo vi pero todavia no te lo dije, espero a confirmarlo
#   anunciado = 1  ya te avise, asi que corresponde avisarte cuando se arregle
avisar_si_cambio() {
    local clave="$1" nivel="$2" titulo="$3" texto="${4:-}" confirmar="${5:-0}"
    local campos nivel_previo desde conf ahora
    ahora=$(date +%s)

    campos=$(_av_leer "$ESTADO_AVISOS" "$clave" || true)
    IFS='|' read -r nivel_previo desde conf <<< "$campos"
    [ -n "${nivel_previo:-}" ] || nivel_previo="bien"
    case "${desde:-}" in ''|*[!0-9]*) desde="$ahora" ;; esac
    case "${conf:-}" in 0|1) ;; *) conf=1 ;; esac

    # ── Nada cambio ───────────────────────────────────────────────────────────
    if [ "$nivel_previo" = "$nivel" ]; then
        [ "$nivel" = "bien" ] && return 0

        # Aca se paga la confirmacion: la primera vez se vio y no se dijo, y
        # como sigue igual, ahora si. Un contenedor que se reinicia treinta
        # segundos durante una actualizacion no puede despertarte, y dos
        # falsas alarmas alcanzan para que silencies el canal para siempre.
        if [ "$conf" = "0" ]; then
            _av_escribir "$ESTADO_AVISOS" "$clave" "$nivel|$ahora|1"
            notificar "$nivel" "$titulo" "$texto"
            evento alerta "$titulo${texto:+ · $texto}"
            return 0
        fi

        # Sigue igual desde hace demasiado: un recordatorio y se reinicia el
        # reloj, para que sea uno cada tanto y no uno por hora.
        [ "${RECORDAR_CADA_HORAS:-0}" -gt 0 ] || return 0
        [ $(( ahora - desde )) -ge $(( RECORDAR_CADA_HORAS * 3600 )) ] || return 0
        _av_escribir "$ESTADO_AVISOS" "$clave" "$nivel|$ahora|1"
        notificar "$nivel" "Sigue: $titulo" "$texto"
        return 0
    fi

    # ── Se arreglo ────────────────────────────────────────────────────────────
    if [ "$nivel" = "bien" ]; then
        _av_escribir "$ESTADO_AVISOS" "$clave" "bien|$ahora|1"
        # No se anuncia como resuelto algo que nunca se anuncio como roto.
        [ "$conf" = "1" ] || return 0
        notificar bien "Resuelto: $titulo" "$texto"
        evento alerta "resuelto: $titulo${texto:+ · $texto}"
        return 0
    fi

    # ── Se rompio ─────────────────────────────────────────────────────────────
    # Solo se escribe cuando cambia, asi el archivo no desgasta la tarjeta.
    if [ "$confirmar" = "1" ]; then
        _av_escribir "$ESTADO_AVISOS" "$clave" "$nivel|$ahora|0"
        return 0
    fi
    _av_escribir "$ESTADO_AVISOS" "$clave" "$nivel|$ahora|1"
    notificar "$nivel" "$titulo" "$texto"
    evento alerta "$titulo${texto:+ · $texto}"
}

# Guarda un numero entre corridas y dice si CRECIO. Devuelve 0 si crecio.
# El valor nuevo queda guardado siempre, haya crecido o no.
#
#   crecio <clave> <valor_actual>
crecio() {
    local clave="_num_$1" actual="$2" previo
    previo=$(_av_leer "$ESTADO_AVISOS" "$clave" || true)
    # Solo se escribe si cambio. Esto se llama una vez por contenedor en cada
    # corrida, asi que escribir siempre serian veintitres reescrituras del
    # archivo por hora sobre la microSD, para guardar los mismos numeros.
    [ "$previo" = "$actual" ] || _av_escribir "$ESTADO_AVISOS" "$clave" "$actual"
    case "$previo" in ''|*[!0-9]*) return 1 ;; esac
    [ "$actual" -gt "$previo" ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  CANILLA 2  ·  EL FEED
#
#  Las notificaciones son para lo que te tiene que interrumpir. El feed es
#  para lo que vale la pena recordar, que es mucho mas ancho: el respaldo que
#  salio bien, el chequeo de discos que dio OK, las importaciones de anoche.
#
#  Y sirve sobre todo el dia que algo se rompe: "se lleno el disco" es una
#  cosa, y "se lleno el disco" con tres lineas mas arriba diciendo "importadas
#  12 peliculas" es otra.
# ══════════════════════════════════════════════════════════════════════════════

# evento <origen> <texto>
#
# El archivo se corta solo y NO usa logrotate. Fue justamente logrotate el que
# se murio en silencio en marzo y dejo crecer pihole.log hasta 1,8 GB, y de
# ahi salio el disco lleno que se llevo puesta la tarjeta. Un feed que depende
# de la pieza que ya fallo no es una buena idea.
evento() {
    local origen="$1" texto="$2" tmp
    mkdir -p "$DATOS" 2>/dev/null || return 0
    printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M')" "$origen" "$texto" >> "$FEED" 2>/dev/null || return 0

    # Se recorta cada tanto y no en cada escritura: reescribir el archivo
    # entero por cada linea seria mucho mas escritura de la que ahorra.
    local lineas
    lineas=$(wc -l < "$FEED" 2>/dev/null | tr -d ' ')
    case "$lineas" in ''|*[!0-9]*) return 0 ;; esac
    [ "$lineas" -gt $(( FEED_LINEAS + 200 )) ] || return 0
    tmp=$(mktemp) || return 0
    tail -n "$FEED_LINEAS" "$FEED" > "$tmp" 2>/dev/null && mv "$tmp" "$FEED"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  CANILLA 3  ·  LAS METRICAS
#
#  node-exporter tiene una puerta de atras que casi nadie usa: lee una carpeta
#  con archivos de texto planos y publica lo que encuentre como metrica propia.
#  Con eso, cualquier script se convierte en exporter sin ser un contenedor.
#
#  QUE VA Y QUE NO
#
#  Solo lo que node-exporter no puede saber solo. El espacio del DAS, la CPU,
#  la RAM y la temperatura ya los tiene: escribirlos de nuevo seria tener dos
#  fuentes para el mismo hecho.
#
#  CUIDADO CON LAS ETIQUETAS
#
#  Adentro de una etiqueta no va NUNCA algo que cambia, como el texto de un
#  error o una fecha. Cada valor distinto crea una serie nueva y Prometheus
#  las guarda todas para siempre: es la forma mas comun de llenar el disco
#  con el sistema que vigila que no se llene el disco.
# ══════════════════════════════════════════════════════════════════════════════

METRICAS=()

# metrica <nombre_con_etiquetas> <valor>
metrica() { METRICAS+=("$1 $2"); }

# ── Las metricas de lo que NO corre en cada vuelta ────────────────────────────
#
# SMART, el espacio del DAS y los huerfanos se miden cada dos dias. Si fueran
# por el mismo archivo que el resto, desaparecerian de Grafana durante 47 horas
# de cada 48, porque el archivo se reescribe entero en cada corrida.
#
# Asi que van a un archivo propio, que se escribe solo cuando esos chequeos
# corren de verdad. Se guarda en disco y no en /run, para que un reinicio no
# borre la ultima medicion: si no, despues de apagar la Pi te quedarias sin
# datos de los discos hasta la ventana siguiente.
METRICAS_GUARDADAS=()
METRICAS_GUARDADAS_ARCHIVO="$DATOS/metricas-lentas.prom"

metrica_guardada() { METRICAS_GUARDADAS+=("$1 $2"); }

metricas_guardadas_volcar() {
    [ ${#METRICAS_GUARDADAS[@]} -gt 0 ] || return 0
    mkdir -p "$DATOS" 2>/dev/null || return 0
    printf '%s\n' "${METRICAS_GUARDADAS[@]}" | sort > "$METRICAS_GUARDADAS_ARCHIVO.tmp" 2>/dev/null \
        && mv "$METRICAS_GUARDADAS_ARCHIVO.tmp" "$METRICAS_GUARDADAS_ARCHIVO"
    return 0
}

# Se copia a /run en CADA corrida, no solo cuando se midio: es lo que hace que
# el dato siga estando despues de un reinicio.
metricas_guardadas_publicar() {
    [ -s "$METRICAS_GUARDADAS_ARCHIVO" ] || return 0
    _av_dir_metricas || return 0
    cp "$METRICAS_GUARDADAS_ARCHIVO" "$METRICAS_DIR/pi-lentas.prom.tmp" 2>/dev/null \
        && mv "$METRICAS_DIR/pi-lentas.prom.tmp" "$METRICAS_DIR/pi-lentas.prom"
    return 0
}

_av_dir_metricas() {
    [ -d "$METRICAS_DIR" ] && return 0
    mkdir -p "$METRICAS_DIR" 2>/dev/null && return 0
    sudo mkdir -p "$METRICAS_DIR" 2>/dev/null || return 1
    sudo chown -R "$(id -u):$(id -g)" "/run/pi-services" 2>/dev/null || return 1
}

# Escribe el archivo ENTERO, nunca agrega, y de forma atomica.
#
#   entero    si solo se agregara, un chequeo que desaparece (un contenedor
#             que borraste) dejaria su metrica congelada en verde para siempre
#   atomico   Prometheus lee cada 15 s y tarde o temprano leeria el archivo a
#             medio escribir. Con un mv, o esta el viejo entero o el nuevo
#             entero, nunca la mitad. Es el error clasico de este collector.
metricas_volcar() {
    [ ${#METRICAS[@]} -gt 0 ] || return 0
    _av_dir_metricas || return 0
    local tmp="$METRICAS_ARCHIVO.tmp"
    # Ordenadas para que las lineas del mismo nombre queden juntas, que es lo
    # que espera el formato. Como el nombre es el prefijo, alcanza con sort.
    printf '%s\n' "${METRICAS[@]}" | sort > "$tmp" 2>/dev/null || return 0
    mv "$tmp" "$METRICAS_ARCHIVO" 2>/dev/null || rm -f "$tmp"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  CADENCIA
#
#  El diagnostico corre cada hora y esa es la pulsacion. Lo pesado no necesita
#  su propio temporizador: declara cada cuanto quiere correr y se saltea el
#  resto de las corridas. Cero unidades de systemd nuevas.
# ══════════════════════════════════════════════════════════════════════════════

# toca_ahora <clave> <cada_horas> <hora_preferida>
#
# Devuelve 0 si le toca correr, y deja anotado el momento. Si por lo que sea
# se paso la hora preferida, corre igual pasado un dia mas: una tarea que se
# saltea en silencio porque nadie estaba a las 4 no sirve de nada.
toca_ahora() {
    local clave="_ult_$1" cada="$2" pref="$3" previo ahora hora
    ahora=$(date +%s); hora=$(date +%-H)
    previo=$(_av_leer "$ESTADO_AVISOS" "$clave" || true)
    case "$previo" in ''|*[!0-9]*) previo=0 ;; esac

    local pasado=$(( ahora - previo ))
    [ "$pasado" -ge $(( cada * 3600 )) ] || return 1
    if [ "$hora" != "$pref" ] && [ "$pasado" -lt $(( (cada + 24) * 3600 )) ]; then
        return 1
    fi
    _av_escribir "$ESTADO_AVISOS" "$clave" "$ahora"
    return 0
}
