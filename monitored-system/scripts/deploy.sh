#!/bin/bash
set -euo pipefail

echo "=== Monitored Node Deployment ==="

# ─── OS setup check ───────────────────────────────────────────────────
if [[ ! -f /etc/sysctl.d/99-monitored-node.conf ]]; then
  echo "WARNING: OS setup has not been run yet."
  echo "  Run: sudo ./setup-os.sh"
  echo "  This configures firewall, SELinux, sysctl, and Docker."
  read -p "Continue anyway? [y/N] " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

# ─── Docker group check ──────────────────────────────────────────────
if ! groups "$USER" | grep -q '\bdocker\b'; then
  echo "User '$USER' is not in the 'docker' group."
  echo "Adding '$USER' to the 'docker' group (requires sudo)..."
  sudo usermod -aG docker "$USER"
  echo "Please log out, log back in, and re-run this script."
  exit 1
fi

# ─── Set script permissions ──────────────────────────────────────────
echo "Setting execute permissions..."
chmod +x ./consul/entrypoint.sh
chmod +x ./node-exporter/entrypoint.sh 2>/dev/null || true
chmod +x ./promtail/entrypoint.sh 2>/dev/null || true
chmod +x ./scripts/deploy.sh
chmod +x ./scripts/teardown.sh

# ─── Load .env ────────────────────────────────────────────────────────
if [ -f .env ]; then
  echo "Loading environment from .env..."
  set -a
  source .env
  set +a
else
  echo "ERROR: .env file not found. Copy .env.example to .env and fill in your values."
  exit 1
fi

# ─── Validate required vars ──────────────────────────────────────────
for var in MONITORING_HOST CONSUL_NODE_NAME CONSUL_ADVERTISE; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is not set in .env"
    exit 1
  fi
done

echo "  MONITORING_HOST  = $MONITORING_HOST"
echo "  CONSUL_NODE_NAME = $CONSUL_NODE_NAME"
echo "  CONSUL_ADVERTISE = $CONSUL_ADVERTISE"

# ─── Clean up previous deployment ────────────────────────────────────
echo "Stopping existing services..."
docker compose down --remove-orphans 2>/dev/null || true

# ─── Deploy ───────────────────────────────────────────────────────────
echo "Building and starting services..."
docker compose up -d --build

echo ""
echo "=== Service Status ==="
docker compose ps

echo ""
echo "=== Deployment Complete ==="
echo "Consul agent will join $MONITORING_HOST"
echo "Node Exporter: http://$CONSUL_ADVERTISE:9100/metrics"
echo "Promtail:      http://$CONSUL_ADVERTISE:9080/ready"
