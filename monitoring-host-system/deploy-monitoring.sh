#!/bin/bash
set -e

echo "Starting Monitoring Host System stack..."
docker compose -f docker-compose.monitoring.yml up -d

echo "Monitoring stack deployed."