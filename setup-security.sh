#!/bin/bash
# setup-security.sh — Pi Services security setup
# Automatically detects running services and configures UFW + fail2ban

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
confirm() {
    read -r -p "$1 [y/N] " response
    [[ "$response" =~ ^[Yy]$ ]]
}

echo ""
echo "================================================"
echo "  Pi Services — Security Setup"
echo "================================================"
echo ""

# ── Detect running services ───────────────────────────────────────────────────
info "Detecting running services..."

CADDY_PORT=$(sudo ss -tlnp | grep docker-proxy | awk '{print $4}' | grep -v '::' | cut -d: -f2 | sort -n | head -1)
PIHOLE_PORT=$(sudo ss -tlnp | grep pihole-FTL | grep -v '::' | grep -v ':53' | awk '{print $4}' | cut -d: -f2 | head -1)
SSH_PORT=$(sudo ss -tlnp | grep sshd | grep -v '::' | awk '{print $4}' | cut -d: -f2 | head -1)
CADDY_LOG=$(docker inspect caddy 2>/dev/null | grep LogPath | awk -F'"' '{print $4}')

echo ""
echo "  Detected configuration:"
echo "  ┌─────────────────────────────────────────┐"
echo "  │ Caddy (reverse proxy) port : ${CADDY_PORT:-not found}"
echo "  │ Pi-hole web UI port        : ${PIHOLE_PORT:-not found}"
echo "  │ SSH port                   : ${SSH_PORT:-not found}"
echo "  │ Caddy log path             : ${CADDY_LOG:0:40}..."
echo "  └─────────────────────────────────────────┘"
echo ""

[ -z "$CADDY_PORT" ]  && error "Could not detect Caddy port. Is Caddy running?"
[ -z "$PIHOLE_PORT" ] && error "Could not detect Pi-hole port. Is Pi-hole running?"
[ -z "$SSH_PORT" ]    && error "Could not detect SSH port."
[ -z "$CADDY_LOG" ]   && error "Could not detect Caddy log path. Is Caddy container running?"

confirm "Does this look correct? Continue with setup?" || { echo "Aborting."; exit 0; }

# ── Disable unused services ───────────────────────────────────────────────────
echo ""
info "Checking for unused services..."

VNC_RUNNING=$(sudo ss -tlnp | grep -c "5900" || true)
RPC_RUNNING=$(sudo ss -tlnp | grep -c "111" || true)

if [ "$VNC_RUNNING" -gt 0 ]; then
    warn "VNC is running on port 5900 (unencrypted remote desktop)"
    if confirm "  Disable VNC?"; then
        sudo systemctl stop vncserver-x11-serviced 2>/dev/null || true
        sudo systemctl disable vncserver-x11-serviced 2>/dev/null || true
        sudo systemctl stop wayvnc 2>/dev/null || true
        sudo systemctl disable wayvnc 2>/dev/null || true
        success "VNC disabled"
    fi
else
    success "VNC not running"
fi

if [ "$RPC_RUNNING" -gt 0 ]; then
    warn "rpcbind is running on port 111 (not needed)"
    if confirm "  Disable rpcbind?"; then
        sudo systemctl stop rpcbind rpcbind.socket 2>/dev/null || true
        sudo systemctl disable rpcbind rpcbind.socket 2>/dev/null || true
        success "rpcbind disabled"
    fi
else
    success "rpcbind not running"
fi

# ── UFW ───────────────────────────────────────────────────────────────────────
echo ""
info "Setting up UFW firewall..."

if ! command -v ufw &>/dev/null; then
    info "Installing UFW..."
    sudo apt install -y ufw
fi

echo ""
echo "  UFW will be configured to:"
echo "  ┌─────────────────────────────────────────┐"
echo "  │ ALLOW port ${SSH_PORT}   (SSH)"
echo "  │ ALLOW port ${CADDY_PORT}    (Caddy / HTTP)"
echo "  │ ALLOW port 53   (Pi-hole DNS)"
echo "  │ DENY  port ${PIHOLE_PORT} (Pi-hole web — Caddy only)"
echo "  └─────────────────────────────────────────┘"
echo ""

if confirm "Apply UFW rules?"; then
    sudo ufw allow "$SSH_PORT"
    sudo ufw allow "$CADDY_PORT"
    sudo ufw allow 53
    sudo ufw deny "$PIHOLE_PORT"
    sudo ufw --force enable
    success "UFW configured and enabled"
    sudo ufw status
else
    warn "UFW setup skipped"
fi

# ── fail2ban ──────────────────────────────────────────────────────────────────
echo ""
info "Setting up fail2ban..."

if ! command -v fail2ban-client &>/dev/null; then
    info "Installing fail2ban..."
    sudo apt install -y fail2ban
fi

echo ""
echo "  fail2ban will be configured with:"
echo "  ┌─────────────────────────────────────────┐"
echo "  │ SSH jail     : 5 failures → 1h ban"
echo "  │ Caddy jail   : 5 failures → 1h ban"
echo "  │ Window       : 10 minutes"
echo "  └─────────────────────────────────────────┘"
echo ""

if confirm "Apply fail2ban configuration?"; then
    # Write filter for Caddy
    sudo tee /etc/fail2ban/filter.d/caddy-auth.conf > /dev/null << 'EOF'
[Definition]
failregex = .*"remote_ip":"<HOST>".*"status":401.*
ignoreregex =
EOF

    # Create stable symlink to Caddy log — survives container recreation
    sudo ln -sf "$CADDY_LOG" /var/log/caddy-access.log
    success "Symlink created: /var/log/caddy-access.log → $CADDY_LOG"

    # Write jail config using stable symlink
    sudo tee /etc/fail2ban/jail.local > /dev/null << EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port    = ${SSH_PORT}

[caddy-auth]
enabled  = true
port     = ${CADDY_PORT}
filter   = caddy-auth
backend  = auto
logpath  = /var/log/caddy-access.log
maxretry = 5
bantime  = 1h
findtime = 10m
EOF

    sudo systemctl enable fail2ban
    sudo systemctl restart fail2ban
    sleep 2
    sudo fail2ban-client status
    success "fail2ban configured"
else
    warn "fail2ban setup skipped"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo "  Setup complete. Current port exposure:"
echo "================================================"
sudo ss -tlnp | grep -v '127.0.0.1' | grep -v '\[::1\]' | grep LISTEN
echo ""
echo -e "${YELLOW}Note:${NC} If you recreate the Caddy container, update the symlink:"
echo "  sudo ln -sf \$(docker inspect caddy | grep LogPath | awk -F'\"' '{print \$4}') /var/log/caddy-access.log"
echo "  sudo systemctl restart fail2ban"
echo ""
