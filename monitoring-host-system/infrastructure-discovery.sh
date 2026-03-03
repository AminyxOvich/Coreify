#!/bin/bash

# Production Targeted Server Discovery
# Discovers only: consul-monitoring-server and monitored-node-** pattern servers
# Generates Prometheus configuration and updates monitoring targets

set -euo pipefail

# Configuration
DB_CONTAINER="monitoring-postgres"
DB_USER="monitoring"
DB_NAME="monitoring"
OUTPUT_CONFIG="/tmp/monitoring-configs/prometheus_file_sd_targets.json"
PROMETHEUS_CONTAINER="prometheus"
LOG_FILE="/var/log/discovery.log"

# Ensure output directory exists
mkdir -p "/tmp/monitoring-configs"

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to discover target servers with specific patterns
discover_infrastructure_servers() {
    set +e  # Temporarily disable strict error handling
    
    local query="
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
    
    local result
    result=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -c "$query" 2>&1 | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    
    # Check if result contains error messages
    if echo "$result" | grep -q "ERROR\|FATAL\|could not connect"; then
        return 1
    fi
    
    if [ "$result" != "null" ] && [ -n "$result" ] && echo "$result" | jq . >/dev/null 2>&1; then
        echo "$result"
        return 0
    else
        return 1
    fi
    
    set -e  # Re-enable strict error handling
}

# Function to validate server connectivity
validate_servers() {
    local servers_json="$1"
    log "Validating server connectivity..."
    
    local total_count=0
    local reachable_count=0
    local reachable_servers=()
    local unreachable_servers=()
    
    # Debug: Check if we can parse the JSON properly
    if ! echo "$servers_json" | jq . >/dev/null 2>&1; then
        log "❌ Invalid JSON format for validation"
        return 1
    fi
    
    # Use process substitution instead of pipeline to avoid subshell
    while IFS=: read -r hostname target; do
        if [ -n "$hostname" ] && [ -n "$target" ]; then
            total_count=$((total_count + 1))
            local ip port
            ip=$(echo "$target" | cut -d: -f1)
            port=$(echo "$target" | cut -d: -f2)
            
            if timeout 5 nc -z "$ip" "$port" 2>/dev/null; then
                log "✅ $hostname ($ip:$port) - Reachable"
                reachable_count=$((reachable_count + 1))
                reachable_servers+=("$hostname")
            else
                log "❌ $hostname ($ip:$port) - Unreachable"
                unreachable_servers+=("$hostname")
            fi
        fi
    done < <(echo "$servers_json" | jq -r '.[] | "\(.labels.hostname):\(.targets[0])"' 2>/dev/null || echo "")
    
    log "Connectivity check complete: $reachable_count/$total_count servers reachable"
    
    # Update database status based on connectivity
    if [ ${#reachable_servers[@]} -gt 0 ] || [ ${#unreachable_servers[@]} -gt 0 ]; then
        update_server_status "${reachable_servers[@]}" "--unreachable--" "${unreachable_servers[@]}"
    fi
}

# Function to generate Prometheus configuration
generate_prometheus_config() {
    local servers_json="$1"
    
    log "Generating Prometheus file service discovery configuration..."
    
    # Generate Prometheus file_sd_config format (just the array of targets)
    echo "$servers_json" | jq . > "$OUTPUT_CONFIG"
    log "✅ File service discovery configuration saved to $OUTPUT_CONFIG"
    
    # Reload Prometheus configuration if container is running
    if docker ps --format "table {{.Names}}" | grep -q "^$PROMETHEUS_CONTAINER$"; then
        log "🔄 Reloading Prometheus configuration..."
        if docker exec "$PROMETHEUS_CONTAINER" pkill -HUP prometheus 2>/dev/null; then
            log "✅ Prometheus configuration reloaded successfully"
        else
            # Alternative reload method using HTTP API
            if curl -X POST http://localhost:9090/-/reload 2>/dev/null; then
                log "✅ Prometheus configuration reloaded via HTTP API"
            else
                log "⚠️  Could not reload Prometheus - configuration will be picked up on next scrape"
            fi
        fi
    else
        log "⚠️  Prometheus container not running - configuration will be loaded on startup"
    fi
}

# Function to update server status based on connectivity
update_server_status() {
    local reachable_servers=("$@")
    local unreachable_servers=()
    
    # Split arguments into reachable and unreachable
    local split_point=-1
    for i in "${!reachable_servers[@]}"; do
        if [[ "${reachable_servers[$i]}" == "--unreachable--" ]]; then
            split_point=$i
            break
        fi
    done
    
    if [ $split_point -gt -1 ]; then
        unreachable_servers=("${reachable_servers[@]:$((split_point+1))}")
        reachable_servers=("${reachable_servers[@]:0:$split_point}")
    fi
    
    # Update reachable servers to 'active' status
    for hostname in "${reachable_servers[@]}"; do
        if [ -n "$hostname" ]; then
            docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "
            UPDATE servers 
            SET status = 'active', last_seen = NOW()
            WHERE hostname = '$hostname';
            " >/dev/null 2>&1
            log "🔄 Updated $hostname status to 'active'"
        fi
    done
    
    # Update unreachable servers to 'not running' status
    for hostname in "${unreachable_servers[@]}"; do
        if [ -n "$hostname" ]; then
            docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "
            UPDATE servers 
            SET status = 'not running'
            WHERE hostname = '$hostname';
            " >/dev/null 2>&1
            log "🔄 Updated $hostname status to 'not running'"
        fi
    done
}

# Function to update server discovery timestamp
update_discovery_timestamp() {
    local timestamp
    timestamp=$(date -u +"%Y-%m-%d %H:%M:%S")
    
    docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "
    UPDATE servers 
    SET last_seen = '$timestamp'
    WHERE status = 'active' 
    AND (hostname LIKE 'monitored-node-%' OR hostname = 'consul-monitoring-server');
    " >/dev/null 2>&1
    
    log "✅ Updated discovery timestamp for target servers"
}

# Function to show discovery summary
show_discovery_summary() {
    log "=== Discovery Summary ==="
    
    local query="
    SELECT 
        hostname,
        host(ip_address) as ip,
        node_type,
        CASE 
            WHEN hostname = 'consul-monitoring-server' THEN '🖥️  Monitoring Server'
            WHEN hostname LIKE 'monitored-node-%' THEN '📡 Monitored Node'
            ELSE '❓ Unknown'
        END as role,
        CASE WHEN prometheus_enabled THEN '✅' ELSE '❌' END as monitoring
    FROM servers 
    WHERE (hostname LIKE 'monitored-node-%' OR hostname = 'consul-monitoring-server')
    AND status = 'active'
    ORDER BY hostname;"
    
    docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "$query" 2>/dev/null
}

# Function to create cron job for automated discovery
setup_automated_discovery() {
    local script_path="$(realpath "$0")"
    local cron_job="*/5 * * * * $script_path --automated >> $LOG_FILE 2>&1"
    
    log "Setting up automated discovery (every 5 minutes)..."
    (crontab -l 2>/dev/null | grep -v "$script_path"; echo "$cron_job") | crontab -
    log "✅ Automated discovery configured"
}

# Main execution
main() {
    # Check if running in automated mode
    if [[ "${1:-}" == "--automated" ]]; then
        log "Running automated discovery..."
    else
        log "=== Infrastructure Server Discovery ==="
        log "Target patterns: consul-monitoring-server, monitored-node-**"
    fi
    
    # Discover servers
    log "Starting infrastructure server discovery..."
    local servers_json
    servers_json=$(discover_infrastructure_servers)
    local discovery_result=$?
    
    # Check if we got valid JSON
    if [ $discovery_result -eq 0 ] && [ -n "$servers_json" ] && echo "$servers_json" | jq . >/dev/null 2>&1; then
        local count=$(echo "$servers_json" | jq '. | length' 2>/dev/null || echo "unknown")
        log "✅ Found $count target servers - proceeding with validation"
        
        # Validate connectivity
        validate_servers "$servers_json"
        
        # Generate configurations
        generate_prometheus_config "$servers_json"
        
        # Update timestamps
        update_discovery_timestamp
        
        # Show summary (only in manual mode)
        if [[ "${1:-}" != "--automated" ]]; then
            show_discovery_summary
            
            log ""
            log "🎯 Target infrastructure discovery complete!"
            log "📁 Configurations available:"
            log "   • $OUTPUT_CONFIG (Prometheus job config)"
            log "   • ${OUTPUT_CONFIG%.json}_file_sd.json (File service discovery)"
            log ""
            log "🔄 To set up automated discovery every 5 minutes, run:"
            log "   $0 --setup-automation"
        fi
        
    else
        log "❌ Discovery failed - no target servers found"
        exit 1
    fi
}

# Handle command line arguments
case "${1:-}" in
    --setup-automation)
        setup_automated_discovery
        ;;
    --automated)
        main "$1"
        ;;
    *)
        main
        ;;
esac
