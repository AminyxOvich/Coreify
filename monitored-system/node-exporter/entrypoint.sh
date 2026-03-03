#!/bin/sh
set -e

# Start the Node Exporter
exec /bin/node_exporter --web.listen-address=:9100 --web.telemetry-path=/metrics