#!/bin/bash
set -euo pipefail

echo "=== Monitoring Host Deployment ==="

# ─── OS setup check ───────────────────────────────────────────────────
if [[ ! -f /etc/sysctl.d/99-monitoring-stack.conf ]]; then
  echo "WARNING: OS setup has not been run yet."
  echo "  Run: sudo ./setup-os.sh"
  echo "  This configures firewall, SELinux, sysctl, and Docker."
  read -p "Continue anyway? [y/N] " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

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

# ─── Pre-flight checks ───────────────────────────────────────────────
echo "Checking prerequisites..."
if ! command -v docker &>/dev/null; then
  echo "ERROR: docker is not installed"
  exit 1
fi

if ! docker compose version &>/dev/null; then
  echo "ERROR: docker compose v2 is required"
  exit 1
fi

# ─── Ensure config directories exist ─────────────────────────────────
mkdir -p ./config/grafana/provisioning/datasources

# ─── Deploy ───────────────────────────────────────────────────────────
echo "Stopping existing services..."
docker compose -f docker-compose.monitoring.yml down --remove-orphans 2>/dev/null || true

echo "Starting monitoring stack..."
docker compose -f docker-compose.monitoring.yml up -d

echo ""
echo "=== Waiting for services to become healthy ==="
echo "Checking health status (timeout: 120s)..."
timeout=120
elapsed=0
while [ $elapsed -lt $timeout ]; do
  healthy=$(docker compose -f docker-compose.monitoring.yml ps --format json 2>/dev/null | grep -c '"healthy"' || echo "0")
  total=$(docker compose -f docker-compose.monitoring.yml ps -q 2>/dev/null | wc -l || echo "0")
  echo "  Healthy: $healthy / $total (${elapsed}s)"
  if [ "$healthy" -eq "$total" ] && [ "$total" -gt 0 ]; then
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

echo ""
echo "=== Service Status ==="
docker compose -f docker-compose.monitoring.yml ps

echo ""
echo "=== Endpoints ==="
echo "  Grafana:    http://localhost:3000  (${GF_ADMIN_USER:-admin} / ****)"
echo "  Prometheus: http://localhost:9090"
echo "  Loki:       http://localhost:3100"
echo "  Consul UI:  http://localhost:8500"
echo "  PostgreSQL: localhost:5432"
echo ""
echo "Monitoring stack deployed successfully."