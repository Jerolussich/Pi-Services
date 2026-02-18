#!/bin/bash
# Wallabag Installation Script
# Read articles without ads, clutter, or paywalls
# Run this script to install or reinstall Wallabag
set -e  # Exit on error

# Configuration — override defaults via env vars or args
CONTAINER_NAME="${WALLABAG_CONTAINER_NAME:-wallabag}"
PORT="${WALLABAG_PORT:-8082}"
PI_IP="${WALLABAG_HOST:-$(hostname -I | awk '{print $1}')}"
DATA_VOLUME="${WALLABAG_DATA_VOLUME:-wallabag-data}"

echo "==================================="
echo "Installing Wallabag..."
echo "==================================="

# Stop and remove existing container if it exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Removing existing Wallabag container..."
    docker stop ${CONTAINER_NAME} 2>/dev/null || true
    docker rm ${CONTAINER_NAME} 2>/dev/null || true
fi

# Run Wallabag
echo "Starting Wallabag container..."
docker run -d \
  --name ${CONTAINER_NAME} \
  -p ${PORT}:80 \
  -v ${DATA_VOLUME}:/var/www/wallabag/data \
  -e SYMFONY__ENV__DOMAIN_NAME="http://${PI_IP}:${PORT}" \
  --restart unless-stopped \
  wallabag/wallabag

echo ""
echo "==================================="
echo "✅ Wallabag installed successfully!"
echo "==================================="
echo ""
echo "Access at: http://${PI_IP}:${PORT}"
echo ""
echo "Default credentials:"
echo "  Username: wallabag"
echo "  Password: wallabag"
echo ""
echo "⚠️  CHANGE THE PASSWORD after first login!"
echo ""
echo "Useful commands:"
echo "  View logs:    docker logs ${CONTAINER_NAME}"
echo "  Stop:         docker stop ${CONTAINER_NAME}"
echo "  Start:        docker start ${CONTAINER_NAME}"
echo "  Restart:      docker restart ${CONTAINER_NAME}"
echo "  Remove:       docker stop ${CONTAINER_NAME} && docker rm ${CONTAINER_NAME}"
