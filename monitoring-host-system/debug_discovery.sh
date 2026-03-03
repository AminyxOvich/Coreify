#!/bin/bash

# Simple debug script to test the discovery function
DB_CONTAINER="monitoring-postgres"
DB_USER="monitoring"
DB_NAME="monitoring"

echo "=== Testing PostgreSQL Query ==="

query="
SELECT json_agg(
    json_build_object(
        'targets', ARRAY[host(ip_address) || ':' || node_exporter_port],
        'labels', json_build_object(
            'hostname', hostname,
            'server_id', server_id,
            'node_type', node_type,
            'instance', hostname,
            'environment', 'production',
            'discovery_method', 'database',
            'server_role', CASE 
                WHEN hostname = 'consul-monitoring-server' THEN 'monitoring-server'
                WHEN hostname LIKE 'monitored-node-%' THEN 'monitored-node'
                ELSE 'unknown'
            END
        )
    )
) 
FROM servers 
WHERE status = 'active' 
AND prometheus_enabled = true
AND (
    hostname LIKE 'monitored-node-%' 
    OR hostname = 'consul-monitoring-server'
);"

echo "Running query..."
result=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -c "$query" 2>&1 | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

echo "Raw result length: ${#result}"
echo "First 200 chars: '${result:0:200}'"
echo ""
echo "Testing jq validation..."
if echo "$result" | jq . >/dev/null 2>&1; then
    echo "✅ JSON is valid"
    echo "Server count: $(echo "$result" | jq '. | length')"
else
    echo "❌ JSON is invalid"
fi

echo ""
echo "Raw result:"
echo "'$result'"