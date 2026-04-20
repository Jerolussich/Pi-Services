#!/bin/bash
# install.sh: setup one-shot de Calibre en el Pi.
# - Instala calibre desde apt
# - Crea e inicializa la carpeta de biblioteca
# - Crea la carpeta de inbox para ingesta automática
# - Instala el systemd user-service de calibre-server + el timer de ingesta
# - Habilita linger para auto-start
#
# Correr como el usuario que va a usar Calibre (NO con sudo).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBRARY="$HOME/calibre-library"
INBOX="$HOME/calibre-inbox"
SERVICE_DIR="$HOME/.config/systemd/user"

echo "==> Instalando calibre via apt..."
sudo apt update
# Los triggers de desktop-file-utils/shared-mime-info pueden tirar "Illegal instruction"
# en Pi 5 con ciertos kernels. Es cosmético (solo afectan asociaciones del escritorio).
# Ignoramos el exit code de apt y verificamos el binario directamente.
sudo apt install -y calibre || true

if ! command -v calibre-server >/dev/null 2>&1; then
    echo "ERROR: calibre-server no se instaló. Revisá los logs de apt."
    exit 1
fi
echo "    ✓ calibre-server OK ($(calibre-server --version 2>/dev/null | head -1 || echo instalado))"

echo "==> Creando biblioteca en $LIBRARY..."
mkdir -p "$LIBRARY"

echo "==> Inicializando biblioteca (crea metadata.db si no existe)..."
# calibre-server falla si la carpeta no tiene metadata.db. calibredb la inicializa.
calibredb list --with-library "$LIBRARY" >/dev/null 2>&1 || true

echo "==> Creando inbox de ingesta automática en $INBOX..."
mkdir -p "$INBOX/failed"

echo "==> Instalando herramientas CLI (calibre-wipe, calibre-ingest)..."
sudo install -m 755 "$REPO_DIR/bin/calibre-wipe" /usr/local/bin/calibre-wipe
sudo install -m 755 "$REPO_DIR/bin/calibre-ingest" /usr/local/bin/calibre-ingest

echo "==> Instalando user-services (calibre-server + calibre-ingest timer)..."
mkdir -p "$SERVICE_DIR"
cp "$REPO_DIR/systemd/calibre-server.service" "$SERVICE_DIR/"
cp "$REPO_DIR/systemd/calibre-ingest.service" "$SERVICE_DIR/"
cp "$REPO_DIR/systemd/calibre-ingest.timer" "$SERVICE_DIR/"

systemctl --user daemon-reload
systemctl --user enable --now calibre-server
systemctl --user enable --now calibre-ingest.timer

echo "==> Habilitando linger para que el server corra sin login..."
sudo loginctl enable-linger "$USER"

echo ""
echo "Listo. Verificá con:"
echo "  systemctl --user status calibre-server"
echo "  systemctl --user list-timers calibre-ingest.timer"
echo "  curl -I http://localhost:8083"
echo ""
echo "El server está corriendo con --enable-local-write, así que desde el web UI"
echo "en http://calibre.pi podés subir libros con el botón 'Add books'."
echo ""
echo "Para ingesta en lote con dedup, dropeás los archivos en $INBOX:"
echo "  scp *.epub $USER@<pi-ip>:calibre-inbox/"
echo "El timer corre cada minuto y los procesa (skipea duplicados)."
