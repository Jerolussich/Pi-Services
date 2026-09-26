#!/bin/bash
# ==============================================================================
#  lib/discos.sh  ·  Preparar el disco del DAS sin romper lo que ya tiene
#
#  No se ejecuta solo: se carga con source desde comun.sh.
#
#  Hasta ahora el instalador sabia DETECTAR que el disco no estaba usable y
#  ofrecia seguir en pausa, pero preparar el disco era un paso manual que habia
#  que leer de media/DAS.md y tipear a mano. Eso significaba que la parte mas
#  delicada de la instalacion -la unica que puede borrar datos- era la unica
#  que no estaba escrita en ningun lado ejecutable.
#
#  Las tres reglas que sigue este archivo:
#
#  1. NUNCA formatear sin que la persona escriba la palabra completa. Un "s"
#     de mas en un [S/n] no puede costar cuatro terabytes.
#  2. Un disco que YA tiene un sistema de archivos se monta, no se formatea.
#     Que el instalador no sepa que hay adentro no lo vuelve vacio.
#  3. Antes de preguntar, explicar que implica. Quien decide tiene que saber
#     que pierde, que gana, y que alternativa hay.
#
#  El esquema siempre es mergerfs, incluso con un solo disco. Cuesta nada hoy
#  y evita tener que desarmar todo el dia que aparezca el segundo: se formatea
#  el nuevo, se monta en /mnt/diskN, y el conjunto lo toma solo. El disco viejo
#  no se toca.
# ==============================================================================

# Sistemas de archivos que sirven para el stack multimedia. La lista es corta
# a proposito: hacen falta hardlinks y permisos POSIX, y eso deja afuera a todo
# lo que viene de Windows.
FS_SIRVEN="ext4 ext3 xfs btrfs"
FS_AJENOS="ntfs ntfs3 exfat vfat fat32 hfsplus"

# ── Que discos hay ────────────────────────────────────────────────────────────

# El disco que aloja la raiz. Se excluye de todo lo de abajo: es la tarjeta del
# sistema y no es candidata a nada.
disco_del_sistema() {
    local fuente; fuente=$(findmnt -no SOURCE / 2>/dev/null)
    [ -n "$fuente" ] || return 1
    lsblk -no PKNAME "$fuente" 2>/dev/null | head -1 | tr -d ' '
}

# Discos enteros que no son el del sistema. Se ignoran los loop (snaps) y los
# que ya estan montados como parte del conjunto.
discos_candidatos() {
    local sistema n tipo
    sistema=$(disco_del_sistema)
    while read -r n tipo; do
        [ "$tipo" = "disk" ] || continue
        [ "$n" = "$sistema" ] || echo "$n"
    done < <(lsblk -dno NAME,TYPE 2>/dev/null)
}

# La particion con filesystem mas grande de un disco, que es la que define de
# que se trata. Devuelve "FSTYPE NOMBRE" o vacio si no hay ninguna.
disco_fs_principal() {
    lsblk -brno NAME,FSTYPE,SIZE "/dev/$1" 2>/dev/null \
        | awk 'NF==3 && $2!="" && $2!="swap" {print $3"\t"$2"\t"$1}' \
        | sort -rn | head -1 | cut -f2,3
}

# El estado de un disco, en una palabra, que es lo que decide la rama:
#   listo  → tiene un FS que sirve; se monta tal cual
#   ajeno  → tiene datos en un FS de Windows; sirve para leer, no para el stack
#   vacio  → no hay ningun filesystem; es candidato a formatear
disco_estado() {
    local fs; fs=$(disco_fs_principal "$1" | cut -f1)
    [ -n "$fs" ] || { echo "vacio"; return 0; }
    [[ " $FS_SIRVEN " == *" $fs "* ]] && { echo "listo"; return 0; }
    [[ " $FS_AJENOS " == *" $fs "* ]] && { echo "ajeno"; return 0; }
    # Un FS que no conocemos se trata como ajeno: en la duda no se formatea.
    echo "ajeno"
}

# Un disco YA en uso no es candidato a nada. Sin esta comprobacion, quien
# corriera el instalador por segunda vez veria su propio disco de 4 TB ofrecido
# como si estuviera libre, y lo peor es que la rama "listo" lo montaria una
# segunda vez en /mnt/disk2: el mismo disco, dos veces, dentro del conjunto.
disco_en_uso() {
    local d="$1" uuid
    # Alguna particion montada en cualquier lado
    lsblk -no MOUNTPOINT "/dev/$d" 2>/dev/null | grep -q . && return 0
    # O declarada en el fstab aunque ahora no este montada
    while read -r uuid; do
        [ -n "$uuid" ] && grep -q "UUID=$uuid" /etc/fstab 2>/dev/null && return 0
    done < <(lsblk -no UUID "/dev/$d" 2>/dev/null)
    return 1
}

# Una linea legible para el menu de seleccion.
disco_descripcion() {
    local d="$1" tam modelo fs part estado
    tam=$(lsblk -dno SIZE "/dev/$d" 2>/dev/null | tr -d ' ')
    modelo=$(lsblk -dno MODEL "/dev/$d" 2>/dev/null | sed 's/ *$//')
    estado=$(disco_estado "$d")
    fs=$(disco_fs_principal "$d" | cut -f1)
    part=$(disco_fs_principal "$d" | cut -f2)

    case "$estado" in
        listo) echo "$tam  ${modelo:-sin modelo}  ·  $fs en $part, se puede usar tal cual" ;;
        ajeno) echo "$tam  ${modelo:-sin modelo}  ·  $fs en $part, tiene datos pero no sirve para el stack" ;;
        *)     echo "$tam  ${modelo:-sin modelo}  ·  sin formatear" ;;
    esac
}

# ── Puntos de montaje y fstab ─────────────────────────────────────────────────

# El primer /mnt/diskN libre. Asi sumar un disco no pisa al anterior ni obliga
# a renumerar nada.
proximo_punto_disco() {
    local i=1
    while grep -qE "^[^#]*[[:space:]]/mnt/disk$i[[:space:]]" /etc/fstab 2>/dev/null; do
        i=$((i + 1))
    done
    echo "/mnt/disk$i"
}

# Todos los /mnt/diskN que ya estan declarados, para rearmar la linea del
# conjunto con las dependencias correctas.
puntos_disco_en_fstab() {
    grep -oE "[[:space:]]/mnt/disk[0-9]+[[:space:]]" /etc/fstab 2>/dev/null \
        | tr -d ' ' | sort -u
}

# Una copia con fecha antes de cada cambio. Un fstab roto deja la maquina sin
# arrancar, y esa es exactamente la clase de error que no se puede deshacer
# por SSH.
respaldar_fstab() {
    local copia="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    sudo cp /etc/fstab "$copia" && info "Copia del fstab en $copia"
}

# ── Explicaciones ─────────────────────────────────────────────────────────────
#
#  Van en funciones y no sueltas en el flujo porque la misma explicacion se usa
#  desde dos ramas distintas, y porque el texto es la parte que mas importa
#  revisar cuando esto se lee dentro de seis meses.

explicar_formateo() {
    local disco="$1" tam contenido
    tam=$(lsblk -dno SIZE "/dev/$disco" 2>/dev/null | tr -d ' ')
    contenido=$(disco_fs_principal "$disco" | cut -f1)

    echo ""
    aviso "${B}Formatear /dev/$disco ($tam) borra todo lo que tenga adentro.${N}"
    echo ""
    if [ -n "$contenido" ]; then
        info "Ese disco tiene un sistema de archivos ${B}$contenido${N} con datos."
        info "No puedo saber que hay: pueden ser fotos, respaldos, o nada."
        info "Si hay algo que te importa, ${B}copialo antes${N} y volve despues."
    else
        info "No encontre ningun sistema de archivos, asi que lo mas probable"
        info "es que este vacio. Igual conviene que lo confirmes vos."
    fi
    echo ""
    info "Lo que va a pasar:"
    gris "   · se borra la tabla de particiones y se crea una sola particion"
    gris "   · se formatea en ext4, que soporta hardlinks y permisos POSIX"
    gris "   · se reserva solo el 1% para root en vez del 5% por defecto,"
    gris "     que en un disco de 4 TB son casi 200 GB que no se desperdician"
    gris "   · se monta por UUID en el fstab con nofail, para que la maquina"
    gris "     arranque igual si algun dia el disco no esta conectado"
    echo ""
    info "Esto ${B}no se puede deshacer${N}."
    echo ""
}

explicar_ajeno() {
    local disco="$1" fs
    fs=$(disco_fs_principal "$disco" | cut -f1)

    echo ""
    aviso "${B}/dev/$disco tiene $fs, que no sirve para el stack multimedia.${N}"
    echo ""
    info "$fs no soporta hardlinks ni permisos POSIX. Sin hardlinks, cuando"
    info "Radarr importa una pelicula no puede enlazarla: la copia. Cada"
    info "titulo termina ocupando el doble, una vez en descargas y otra en"
    info "la biblioteca, y el disco se llena a la mitad de lo que deberia."
    echo ""
    info "Ademas los contenedores no pueden manejar dueño ni permisos, asi"
    info "que es probable que ni siquiera puedan escribir."
    echo ""
}

# ── El flujo ──────────────────────────────────────────────────────────────────

# Formatea y deja montado. Devuelve 0 solo si el disco quedo usable.
formatear_disco() {
    local disco="$1" punto="$2" etiqueta uuid

    etiqueta="${punto##*/}"          # /mnt/disk1 → disk1

    info "Borrando tabla de particiones de /dev/$disco..."
    sudo sgdisk --zap-all "/dev/$disco" >/dev/null 2>&1 || { falla "No pude limpiar la tabla"; return 1; }

    info "Creando una particion sobre todo el disco..."
    sudo sgdisk -n 1:0:0 -t 1:8300 -c "1:$etiqueta" "/dev/$disco" >/dev/null 2>&1 \
        || { falla "No pude crear la particion"; return 1; }
    sudo partprobe "/dev/$disco" >/dev/null 2>&1; sleep 2

    # La particion NO se arma pegando un "1" al nombre del disco. En sdb eso da
    # sdb1 y funciona, pero en un NVMe o una eMMC la particion de nvme0n1 es
    # nvme0n1p1, no nvme0n11. Se la pregunta a lsblk, que siempre acierta.
    local particion
    particion=$(lsblk -lno NAME,TYPE "/dev/$disco" 2>/dev/null | awk '$2=="part"{print $1; exit}')
    [ -n "$particion" ] || { falla "No aparecio la particion despues de crearla"; return 1; }
    particion="/dev/$particion"

    info "Formateando en ext4 (puede tardar un minuto)..."
    sudo mkfs.ext4 -q -m 1 -L "$etiqueta" "$particion" \
        || { falla "No pude formatear $particion"; return 1; }

    uuid=$(sudo blkid -s UUID -o value "$particion" 2>/dev/null)
    [ -n "$uuid" ] || { falla "El disco quedo sin UUID, algo salio mal"; return 1; }

    ok "Formateado: $particion · UUID $uuid"
    montar_disco "$uuid" "$punto"
}

# Agrega un disco ya formateado al fstab y lo monta. Idempotente: si el UUID
# ya estaba declarado no lo duplica.
montar_disco() {
    local uuid="$1" punto="$2"

    sudo mkdir -p "$punto"

    if grep -q "UUID=$uuid" /etc/fstab 2>/dev/null; then
        info "El UUID ya estaba en el fstab, no lo duplico"
    else
        respaldar_fstab
        printf '\n# DAS · disco montado por el instalador el %s\nUUID=%s  %s  ext4  defaults,nofail,x-systemd.device-timeout=10  0  2\n' \
            "$(date +%F)" "$uuid" "$punto" | sudo tee -a /etc/fstab >/dev/null
        ok "Agregado al fstab: $punto"
    fi

    sudo systemctl daemon-reload 2>/dev/null
    sudo mount "$punto" 2>/dev/null || sudo mount -a 2>/dev/null
    mountpoint -q "$punto" || { falla "No quedo montado en $punto"; return 1; }
    ok "Montado en $punto"
}

# Rearma la linea del conjunto. Se regenera entera en vez de editarse porque
# las dependencias cambian cada vez que se suma un disco, y un x-systemd.requires
# que apunta a un disco que ya no existe deja el arranque esperando.
armar_conjunto() {
    local raiz="$1" puntos requiere opciones

    command -v mergerfs >/dev/null 2>&1 || {
        info "Instalando mergerfs..."
        sudo apt-get install -y mergerfs >/dev/null 2>&1 || { falla "No pude instalar mergerfs"; return 1; }
    }

    puntos=$(puntos_disco_en_fstab)
    [ -n "$puntos" ] || { falla "No hay ningun /mnt/diskN en el fstab"; return 1; }

    requiere=$(echo "$puntos" | sed 's/^/x-systemd.requires=/' | paste -sd, -)
    opciones="defaults,allow_other,use_ino,cache.files=partial,dropcacheonclose=true"
    opciones="$opciones,category.create=mfs,moveonenospc=true,minfreespace=20G,fsname=das,$requiere"

    local deseada; deseada="/mnt/disk*  $raiz  fuse.mergerfs  $opciones  0  0"

    # Si la linea ya es exactamente la que queremos y el conjunto esta montado,
    # no se toca nada. Remontar /mnt/das con los contenedores arriba es peor que
    # no hacer nada: Jellyfin y los *arr tienen el bind-mount abierto y quedan
    # mirando un montaje viejo hasta que se los reinicia.
    if grep -qxF "$deseada" /etc/fstab 2>/dev/null && mountpoint -q "$raiz"; then
        ok "El conjunto ya estaba montado en $raiz con la configuracion correcta"
        return 0
    fi

    sudo mkdir -p "$raiz"

    # Hay que remontar. Si hay contenedores usando el DAS, avisar antes.
    if mountpoint -q "$raiz" && [ -n "$($DOCKER ps --filter status=running -q 2>/dev/null)" ]; then
        aviso "Voy a remontar $raiz y hay contenedores corriendo."
        info "Despues de esto hay que reiniciarlos para que vean el montaje nuevo."
        pendiente "Reiniciar los contenedores de multimedia: cambio el montaje de $raiz"
    fi

    if grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null; then
        respaldar_fstab
        sudo sed -i '/fuse\.mergerfs/d' /etc/fstab
    fi
    printf '%s\n' "$deseada" | sudo tee -a /etc/fstab >/dev/null

    sudo systemctl daemon-reload 2>/dev/null
    mountpoint -q "$raiz" && sudo umount "$raiz" 2>/dev/null
    sudo mount "$raiz" 2>/dev/null || sudo mount -a 2>/dev/null

    mountpoint -q "$raiz" || { falla "El conjunto no quedo montado en $raiz"; return 1; }
    ok "Conjunto mergerfs montado en $raiz ($(df -h --output=size "$raiz" | tail -1 | tr -d ' '))"
}

# La estructura va creada A TRAVES del conjunto, nunca en cada disco por
# separado: si se crea en los discos sueltos, mergerfs ve la misma carpeta
# duplicada y el reparto de archivos se vuelve impredecible.
crear_estructura() {
    local raiz="$1" ya=0
    [ -d "$raiz/media/movies" ] && [ -d "$raiz/downloads/complete" ] && ya=1

    sudo mkdir -p "$raiz/downloads/complete" "$raiz/downloads/incomplete" \
                  "$raiz/media/movies" "$raiz/media/tv"

    # El chown recursivo va UNA sola vez, al crear. En una segunda corrida el
    # disco ya tiene la biblioteca adentro: recorrer cientos de miles de
    # archivos tarda una eternidad, y peor, pisaria los dueños que los propios
    # contenedores le pusieron a lo suyo.
    if [ "$ya" = "1" ]; then
        sudo chown "$(id -u):$(id -g)" "$raiz" "$raiz/downloads" "$raiz/media" 2>/dev/null
        ok "La estructura ya existia en $raiz, la dejo como esta"
    else
        sudo chown -R "$(id -u):$(id -g)" "$raiz"
        ok "Estructura creada en $raiz"
    fi
}

# Esta prueba vale por todo lo demas. Si los hardlinks no funcionan el stack
# duplica el espacio de cada pelicula en silencio, y te enteras cuando el disco
# esta lleno y ya es tarde.
probar_hardlinks() {
    local raiz="$1" a="$raiz/.prueba-hardlink-a" b="$raiz/.prueba-hardlink-b" r
    rm -f "$a" "$b" 2>/dev/null
    echo prueba > "$a" 2>/dev/null || { falla "No puedo escribir en $raiz"; return 1; }
    ln "$a" "$b" 2>/dev/null || { falla "No se pudieron crear hardlinks en $raiz"; rm -f "$a"; return 1; }
    r=$(stat -c "%h %i" "$a" "$b" | sort -u | wc -l)
    rm -f "$a" "$b" 2>/dev/null
    if [ "$r" = "1" ]; then
        ok "Hardlinks funcionando: cada pelicula va a ocupar espacio una sola vez"
        return 0
    fi
    falla "Los hardlinks no se detectan bien (falta use_ino en el montaje)"
    return 1
}

# El flujo completo. Devuelve 0 si el DAS quedo usable.
preparar_das() {
    local raiz; raiz=$(das_ruta)
    local libres=() usados=() d n=0 elegido estado punto uuid r

    titulo "Preparar el disco del DAS"

    # Los que ya estan en uso se separan de los libres. Es la diferencia entre
    # una primera corrida y la quinta: en la quinta, el unico disco conectado
    # suele ser el que ya esta trabajando, y no hay nada que preparar.
    while read -r d; do
        [ -n "$d" ] || continue
        if disco_en_uso "$d"; then usados+=("$d"); else libres+=("$d"); fi
    done < <(discos_candidatos)

    if [ ${#usados[@]} -gt 0 ]; then
        info "Discos que ya estan en uso:"
        for d in "${usados[@]}"; do
            gris "   · /dev/$d   $(lsblk -no MOUNTPOINT "/dev/$d" 2>/dev/null | grep . | paste -sd' ' -)"
        done
        echo ""
    fi

    if [ ${#libres[@]} -eq 0 ]; then
        if das_montado; then
            ok "Ya esta todo configurado: $raiz montado con $(das_libre) libres."
            info "Para sumar otro disco, conectalo y volve a correr esto."
            return 0
        fi
        aviso "No encontre ningun disco libre para preparar."
        info "Conecta el disco y volve a correr el instalador."
        return 1
    fi

    das_montado && info "El DAS ya funciona. Lo de abajo suma un disco mas al conjunto."

    info "Discos disponibles:"
    echo ""
    for d in "${libres[@]}"; do
        n=$((n + 1))
        echo "     ${B}$n${N})  /dev/$d   $(disco_descripcion "$d")"
    done
    echo ""
    echo "     ${B}0${N})  ninguno, seguir sin tocar nada"
    echo ""

    read -r -p "     ${B}Cual uso${N} [0-$n]: " r </dev/tty 2>/dev/null || r=0
    if [ -z "$r" ] || [ "$r" = "0" ]; then
        info "No toco ningun disco."
        return 1
    fi
    if ! [[ "$r" =~ ^[0-9]+$ ]] || [ "$r" -gt "${#libres[@]}" ]; then
        aviso "Opcion invalida"
        return 1
    fi

    elegido="${libres[$((r - 1))]}"
    estado=$(disco_estado "$elegido")
    punto=$(proximo_punto_disco)

    case "$estado" in
        listo)
            # Ya tiene un FS que sirve. No se formatea: se usa.
            uuid=$(sudo blkid -s UUID -o value "/dev/$(disco_fs_principal "$elegido" | cut -f2)" 2>/dev/null)
            ok "/dev/$elegido ya tiene un sistema de archivos usable. Lo monto sin tocar los datos."
            montar_disco "$uuid" "$punto" || return 1
            ;;

        ajeno)
            explicar_ajeno "$elegido"
            echo "     ${B}1${N})  formatear en ext4   ${R}(borra todo)${N}"
            echo "     ${B}2${N})  no tocarlo, seguir sin disco   ${G}(recomendado)${N}"
            gris "         copiá lo que haya a otro lado y volvé a correr esto"
            echo ""
            read -r -p "     ${B}Que hago${N} [1/2]: " r </dev/tty 2>/dev/null || r=2
            [ "$r" = "1" ] || { info "No toco el disco"; return 1; }
            confirmar_formateo "$elegido" || return 1
            formatear_disco "$elegido" "$punto" || return 1
            ;;

        *)
            confirmar_formateo "$elegido" || return 1
            formatear_disco "$elegido" "$punto" || return 1
            ;;
    esac

    armar_conjunto "$raiz" || return 1
    crear_estructura "$raiz"
    probar_hardlinks "$raiz" || return 1

    echo ""
    ok "${B}El DAS quedo listo en $raiz, con $(das_libre) libres.${N}"
    return 0
}

# La palabra completa, no un [S/n]. Es la unica accion del instalador que
# destruye datos y no se puede deshacer.
confirmar_formateo() {
    local disco="$1" r
    explicar_formateo "$disco"
    read -r -p "     Escribi ${B}FORMATEAR${N} para confirmar: " r </dev/tty 2>/dev/null || r=""
    if [ "$r" != "FORMATEAR" ]; then
        info "No formateo nada."
        return 1
    fi
    return 0
}
