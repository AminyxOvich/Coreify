#!/bin/sh
set -e

echo "MONITORING_HOST is: [${MONITORING_HOST}]"
echo "CONSUL_NODE_NAME is: [${CONSUL_NODE_NAME}]"
echo "CONSUL_ADVERTISE is: [${CONSUL_ADVERTISE}]"
BIND_IP=$(hostname -i | awk '{print $1}')
echo "Calculated BIND_IP is: [${BIND_IP}]"

# Process the template file and replace environment variables
cat /consul/config/consul.hcl.template | envsubst > /consul/config/consul.hcl

# Start Consul with the processed config file
exec consul agent \
  -retry-join="${MONITORING_HOST}" \
  -data-dir="/consul/data" \
  -node="${CONSUL_NODE_NAME}" \
  -bind="${BIND_IP}" \
  -advertise="${CONSUL_ADVERTISE}" \
  -client="0.0.0.0" \
  -config-file=/consul/config/consul.hcl
