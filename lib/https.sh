# ==============================================================================
#  HTTPS CON EL CERTIFICADO DE TAILSCALE
#
#  Todo entra por HTTP pelado. Eso no es solo la advertencia del navegador: hay
#  cosas que directamente NO funcionan sin HTTPS, como las notificaciones web y
#  parte de las capacidades de las apps instaladas desde el navegador. Los
#  gestores de contrasenas tambien se portan mejor.
#
#  Tailscale emite certificados de verdad, de Let's Encrypt, para el nombre de
#  esta maquina dentro de tu tailnet. Gratis, sin abrir un puerto en el router y
#  sin que el nombre exista en el DNS publico.
#
#  ── Lo que esto SI resuelve y lo que NO ──────────────────────────────────────
#
#  El certificado sirve para UN nombre: el de la maquina en la tailnet. No es un
#  comodin y no puede serlo, porque `.pi` no es un dominio real y ninguna
#  autoridad puede firmar algo asi.
#
#  Entonces: quedas con HTTPS de verdad, con candado y sin advertencias, en
#  https://<tu-maquina>.ts.net, que es como vas a entrar desde el celular
#  estando afuera. Los nombres .pi de la red de casa siguen en HTTP.
#
#  Que los .pi tengan HTTPS exigiria una autoridad propia y andar instalando su
#  certificado raiz en cada telefono, cada tele y cada computadora. Es peor el
#  remedio: si un dispositivo no la tiene, ese servicio pasa de "sin candado" a
#  "sitio peligroso", que es un retroceso.
# ==============================================================================

HTTPS_CERT_DIR="/var/lib/pi-services/certs"

# ── Datos ─────────────────────────────────────────────────────────────────────

# El nombre completo de esta maquina en la tailnet, sin el punto final.
https_nombre_tailnet() {
    command -v tailscale >/dev/null 2>&1 || return 1
    tailscale status --json 2>/dev/null | python3 -c \
        'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null
}

# Si la tailnet tiene HTTPS habilitado. Se pregunta por un certificado con
# validez minima de un segundo: sin HTTPS contesta el error sin emitir nada, y
# con HTTPS devuelve el que ya tenga sin gastar una emision nueva.
https_habilitado() {
    local nombre="$1"
    ! sudo tailscale cert --min-validity 1s --cert-file /dev/null --key-file /dev/null \
        "$nombre" 2>&1 | grep -qi "does not support getting TLS certs"
}

# ── Emitir y renovar ──────────────────────────────────────────────────────────
#
#  Es la misma operacion. Tailscale devuelve el certificado que ya tiene si le
#  queda mas validez que la pedida, asi que llamarlo de mas no gasta emisiones
#  ni toca Let's Encrypt. Con --min-validity 720h renueva recien cuando faltan
#  menos de 30 dias.
https_emitir() {
    local nombre="$1"
    sudo mkdir -p "$HTTPS_CERT_DIR" 2>/dev/null || return 1
    sudo tailscale cert --min-validity 720h \
        --cert-file "$HTTPS_CERT_DIR/tailnet.crt" \
        --key-file  "$HTTPS_CERT_DIR/tailnet.key" \
        "$nombre" >/dev/null 2>&1
    # La clave privada queda solo para root, que es con quien corre Caddy
    # adentro del contenedor. No hace falta aflojarla.
    sudo chmod 600 "$HTTPS_CERT_DIR/tailnet.key" 2>/dev/null
    sudo chmod 644 "$HTTPS_CERT_DIR/tailnet.crt" 2>/dev/null
    [ -s "$HTTPS_CERT_DIR/tailnet.crt" ]
}

# Cuantos dias le quedan al certificado que tenemos. Vacio si no hay.
https_dias_restantes() {
    local fin
    fin=$(sudo openssl x509 -in "$HTTPS_CERT_DIR/tailnet.crt" -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$fin" ] || return 1
    python3 -c "
import sys, datetime
try:
    f = datetime.datetime.strptime('$fin'.strip(), '%b %d %H:%M:%S %Y %Z')
    print((f - datetime.datetime.utcnow()).days)
except Exception:
    sys.exit(1)" 2>/dev/null
}

# ── El bloque de Caddy ────────────────────────────────────────────────────────
#
#  Va en un archivo aparte que el Caddyfile importa con un comodin. Asi el
#  bloque existe solo si hay certificado: sin archivo no hay import y Caddy
#  levanta igual. Meterlo en el Caddyfile principal obligaria a que el nombre de
#  la tailnet, que es distinto en cada instalacion, estuviera versionado.
https_escribir_bloque() {
    local nombre="$1" extra="$REPO/caddy/extra"
    mkdir -p "$extra" 2>/dev/null || return 1

    cat > "$extra/tailscale.caddy" <<CADDY
# Generado por el instalador. No lo edites a mano: se reescribe.
#
# El certificado lo emite Tailscale y vale para este nombre solamente. Es la
# puerta de entrada con candado desde afuera de casa.
https://$nombre {
    import accesslog
    tls /certs/tailnet.crt /certs/tailnet.key
    basic_auth {
        {\$CADDY_USER} {\$CADDY_PASSWORD_HASH}
    }
    reverse_proxy homepage:3000
}
CADDY
    [ -s "$extra/tailscale.caddy" ]
}

# ── El recorrido ──────────────────────────────────────────────────────────────

configurar_https() {
    local nombre dias

    nombre=$(https_nombre_tailnet)
    if [ -z "$nombre" ]; then
        return 0   # sin Tailscale no hay nada que hacer, y ya se avisa en su paso
    fi

    if ! https_habilitado "$nombre"; then
        echo ""
        aviso "Tu tailnet no tiene HTTPS habilitado, y es gratis"
        gris "     Tendrias candado de verdad en ${B}https://$nombre${N} sin abrir"
        gris "     ningun puerto. Hoy todo entra por HTTP pelado, y hay cosas que"
        gris "     no funcionan sin HTTPS: las notificaciones del navegador y"
        gris "     parte de las apps instaladas desde el navegador."
        info "Se prende en ${B}login.tailscale.com${N}, en DNS, HTTPS Certificates."
        pendiente "Habilitar HTTPS Certificates en login.tailscale.com (es un boton)"
        return 0
    fi

    # Ya configurado y con el certificado vigente: no hay nada que rehacer.
    if [ -f "$REPO/caddy/extra/tailscale.caddy" ] && dias=$(https_dias_restantes); then
        if [ "$dias" -gt 30 ] 2>/dev/null; then
            gris "     HTTPS ya estaba, y al certificado le quedan $dias dias"
            return 0
        fi
    fi

    echo ""
    info "Tu tailnet emite certificados, asi que te dejo HTTPS de verdad en"
    info "${B}https://$nombre${N}, con candado y sin advertencias."
    gris "     Los nombres .pi de la red de casa siguen en HTTP: el certificado"
    gris "     vale para ese nombre y .pi no es un dominio real, asi que ninguna"
    gris "     autoridad puede firmarlo."
    echo ""

    if ! https_emitir "$nombre"; then
        aviso "No pude emitir el certificado"
        pendiente "Emitir el certificado:  sudo tailscale cert $nombre"
        return 1
    fi
    dias=$(https_dias_restantes)
    ok "Certificado emitido${dias:+, valido $dias dias}"

    if ! https_escribir_bloque "$nombre"; then
        aviso "No pude escribir la configuracion de Caddy"
        return 1
    fi
    ok "Caddy configurado para servir ese nombre por HTTPS"

    # El 443 hay que abrirlo: el firewall deniega todo lo que no este declarado
    if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        sudo ufw allow 443 >/dev/null 2>&1
        ok "Puerto 443 abierto en el firewall"
    fi

    info "Recreo Caddy para que tome el certificado..."
    (cd "$REPO" && $DOCKER compose up -d caddy) >/dev/null 2>&1
    sleep 4

    if ! esta_arriba caddy; then
        falla "Caddy no volvio a levantar"
        gris "     los logs:  docker logs caddy"
        pendiente "Revisar Caddy despues de configurar HTTPS"
        return 1
    fi

    # La prueba de verdad: pedirle la pagina por HTTPS y que el certificado
    # valide contra las autoridades del sistema, sin --insecure.
    local codigo
    codigo=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$nombre/" 2>/dev/null)
    case "$codigo" in
        200|401)
            ok "HTTPS andando en ${B}https://$nombre${N}"
            gris "     el 401 es la contrasena de siempre, usuario admin"
            ;;
        *)
            aviso "Caddy levanto pero HTTPS todavia no contesta (codigo ${codigo:-sin respuesta})"
            gris "     puede tardar unos segundos, o faltar que Tailscale propague el nombre"
            pendiente "Probar https://$nombre desde el celular"
            ;;
    esac
    echo ""
    return 0
}
