#!/bin/bash

# Production-Ready Targeted Server Discovery Demo
# Demonstrates the complete targeted discovery workflow
# Focuses on: consul-monitoring-server and monitored-node-** patterns

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/tmp/monitoring-configs"
DB_CONTAINER="monitoring-postgres"

# Create config directory
mkdir -p "$CONFIG_DIR"

echo "=== Production-Ready Targeted Server Discovery ==="
echo "Target patterns: consul-monitoring-server, monitored-node-**"
echo ""

# Function to check database connectivity
check_database() {
    echo "1. Checking database connectivity..."
    if docker exec "$DB_CONTAINER" psql -U monitoring -d monitoring -c "SELECT 1;" >/dev/null 2>&1; then
        echo "   ✅ PostgreSQL database connected"
        return 0
    else
        echo "   ❌ PostgreSQL database not available"
        return 1
    fi
}

# Function to show current target infrastructure
show_target_infrastructure() {
    echo "2. Current target infrastructure:"
    
    docker exec "$DB_CONTAINER" psql -U monitoring -d monitoring -c "
    SELECT 
        hostname,
        host(ip_address) as ip_address,
        node_type,
        status,
        CASE 
            WHEN hostname = 'consul-monitoring-server' THEN '🖥️  Monitoring Server'
            WHEN hostname LIKE 'monitored-node-%' THEN '📡 Monitored Node'
            ELSE '❓ Other'
        END as server_role,
        CASE WHEN prometheus_enabled THEN '✅' ELSE '❌' END as monitoring_enabled,
        last_seen
    FROM servers 
    WHERE (hostname LIKE 'monitored-node-%' OR hostname = 'consul-monitoring-server')
    ORDER BY 
        CASE WHEN hostname = 'consul-monitoring-server' THEN 1 ELSE 2 END,
        hostname;
    " 2>/dev/null
}

# Function to generate production configurations
generate_production_configs() {
    echo "3. Generating production monitoring configurations..."
    
    # Generate Prometheus target configuration
    local targets_json
    targets_json=$(docker exec "$DB_CONTAINER" psql -U monitoring -d monitoring -t -c "
    SELECT json_agg(
        json_build_object(
            'targets', ARRAY[host(ip_address) || ':' || node_exporter_port],
            'labels', json_build_object(
                'hostname', hostname,
                'server_id', server_id,
                'node_type', node_type,
                'instance', hostname,
                'environment', 'production',
                'discovery_method', 'automated',
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
    );
    " 2>/dev/null | tr -d '[:space:]')
    
    if [ "$targets_json" != "null" ] && [ -n "$targets_json" ]; then
        # Generate complete Prometheus job configuration
        cat > "$CONFIG_DIR/prometheus_production_config.json" << EOF
{
  "job_name": "production-infrastructure-monitoring",
  "honor_labels": true,
  "scrape_interval": "15s",
  "scrape_timeout": "10s",
  "metrics_path": "/metrics",
  "scheme": "http",
  "static_configs": $targets_json
}
EOF
        
        # Generate file service discovery format
        echo "$targets_json" | jq '.' > "$CONFIG_DIR/prometheus_file_sd_targets.json"
        
        # Generate Prometheus YAML snippet for integration
        cat > "$CONFIG_DIR/prometheus_integration.yml" << EOF
# Add this job to your prometheus.yml configuration
scrape_configs:
  - job_name: "production-infrastructure-monitoring"
    honor_labels: true
    scrape_interval: 15s
    scrape_timeout: 10s
    metrics_path: /metrics
    scheme: http
    file_sd_configs:
      - files:
          - "$CONFIG_DIR/prometheus_file_sd_targets.json"
        refresh_interval: 30s
EOF
        
        local server_count
        server_count=$(echo "$targets_json" | jq '. | length' 2>/dev/null || echo "0")
        
        echo "   ✅ Generated configurations for $server_count target servers"
        echo "   📁 Production configs saved to: $CONFIG_DIR/"
        
        return 0
    else
        echo "   ❌ No target servers found for configuration generation"
        return 1
    fi
}

# Function to validate server connectivity
validate_connectivity() {
    echo "4. Validating server connectivity..."
    
    local total_servers=0
    local reachable_servers=0
    
    docker exec "$DB_CONTAINER" psql -U monitoring -d monitoring -t -c "
    SELECT hostname, host(ip_address), node_exporter_port 
    FROM servers 
    WHERE status = 'active' 
    AND (hostname LIKE 'monitored-node-%' OR hostname = 'consul-monitoring-server');
    " 2>/dev/null | while read -r line; do
        if [ -n "$line" ] && [[ ! "$line" =~ ^[[:space:]]*$ ]]; then
            hostname=$(echo "$line" | awk '{print $1}')
            ip=$(echo "$line" | awk '{print $3}')
            port=$(echo "$line" | awk '{print $5}')
            
            if [ -n "$ip" ] && [ -n "$port" ]; then
                total_servers=$((total_servers + 1))
                echo -n "   Testing $hostname ($ip:$port)... "
                
                if timeout 5 nc -z "$ip" "$port" 2>/dev/null; then
                    echo "✅ Reachable"
                    reachable_servers=$((reachable_servers + 1))
                else
                    echo "❌ Unreachable"
                fi
            fi
        fi
    done
}

# Function to show automation options
show_automation_options() {
    echo "5. Production automation options:"
    echo ""
    echo "   🔄 Automated Discovery Setup:"
    echo "      • Database-based discovery: Every 5 minutes"
    echo "      • Network-based discovery: Every 2 hours"
    echo "      • Configuration generation: After each discovery"
    echo ""
    echo "   📅 Cron job examples:"
    echo "      */5 * * * * $SCRIPT_DIR/infrastructure-discovery.sh --automated"
    echo "      0 */2 * * * $SCRIPT_DIR/network-discovery.sh --automated"
    echo "      */10 * * * * $SCRIPT_DIR/test-targeted-discovery.sh >/dev/null 2>&1"
    echo ""
    echo "   📁 Integration with monitoring stack:"
    echo "      • Copy generated configs to Prometheus configuration directory"
    echo "      • Use file_sd_configs for dynamic target updates"
    echo "      • Set up file watchers for automatic Prometheus reloads"
}

# Function to create integration guide
create_integration_guide() {
    cat > "$CONFIG_DIR/integration_guide.md" << 'EOF'
# Targeted Server Discovery Integration Guide

## Overview
This system discovers and monitors servers matching specific patterns:
- `consul-monitoring-server` - Monitoring infrastructure
- `monitored-node-**` - Target nodes for monitoring

## Production Integration Steps

### 1. Prometheus Integration
```yaml
# Add to prometheus.yml
scrape_configs:
  - job_name: "production-infrastructure-monitoring"
    honor_labels: true
    scrape_interval: 15s
    file_sd_configs:
      - files:
          - "/path/to/prometheus_file_sd_targets.json"
        refresh_interval: 30s
```

### 2. Automated Discovery Setup
```bash
# Setup cron jobs for automated discovery
crontab -e

# Add these lines:
*/5 * * * * /path/to/infrastructure-discovery.sh --automated >> /var/log/discovery.log 2>&1
0 */2 * * * /path/to/network-discovery.sh --automated >> /var/log/discovery.log 2>&1
```

### 3. Monitoring Configuration
- Server connectivity alerts
- Discovery failure notifications
- Target server health monitoring

### 4. Scaling Considerations
- Database connection pooling
- Network discovery optimization
- Configuration update batching

## File Descriptions
- `prometheus_production_config.json` - Complete Prometheus job config
- `prometheus_file_sd_targets.json` - File service discovery targets
- `prometheus_integration.yml` - YAML configuration snippet

## Troubleshooting
1. Check database connectivity
2. Verify server patterns in database
3. Test network connectivity to targets
4. Monitor discovery logs for errors
EOF

    echo "   📋 Integration guide created: $CONFIG_DIR/integration_guide.md"
}

# Main execution
main() {
    if check_database; then
        echo ""
        show_target_infrastructure
        echo ""
        
        if generate_production_configs; then
            echo ""
            validate_connectivity
            echo ""
            show_automation_options
            echo ""
            create_integration_guide
            echo ""
            echo "=== Targeted Discovery Summary ==="
            echo "✅ Successfully configured targeted monitoring for:"
            echo "   • consul-monitoring-server (Monitoring infrastructure)"
            echo "   • monitored-node-** pattern servers (Target monitoring nodes)"
            echo ""
            echo "📁 Production-ready configurations generated in:"
            echo "   $CONFIG_DIR/"
            echo ""
            echo "🔗 Files created:"
            ls -la "$CONFIG_DIR/" | tail -n +2 | while read -r line; do
                filename=$(echo "$line" | awk '{print $9}')
                if [ "$filename" != "." ] && [ "$filename" != ".." ]; then
                    echo "   • $filename"
                fi
            done
            echo ""
            echo "🎯 Next steps:"
            echo "   1. Review $CONFIG_DIR/integration_guide.md"
            echo "   2. Integrate configurations with your Prometheus setup"
            echo "   3. Set up automated discovery scheduling"
            echo "   4. Configure monitoring alerts for target infrastructure"
        else
            echo ""
            echo "❌ Configuration generation failed"
            exit 1
        fi
    else
        echo ""
        echo "❌ Database not available - please start the monitoring stack"
        echo "   cd $SCRIPT_DIR && docker-compose -f docker-compose.monitoring.yml up -d"
        exit 1
    fi
}

# Execute main function
main "$@"
