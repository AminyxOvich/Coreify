#!/bin/bash
set -euo pipefail

echo "=== Monitored Node Teardown ==="

# Stop and remove containers
echo "Stopping services..."
docker compose down --remove-orphans

# Ask before removing volumes
read -p "Remove persistent volumes (consul-data, promtail-positions)? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "Removing volumes..."
  docker compose down -v
fi

echo "Teardown completed."