#!/bin/bash

# Comprehensive Server Discovery Automation
# Integrates database-based and network-based discovery for targeted monitoring
# Focuses on: consul-monitoring-server and monitored-node-** patterns

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/discovery-automation.log"
CONFIG_DIR="/tmp/monitoring-configs"
DB_CONTAINER="monitoring-postgres"

# Create config directory
mkdir -p "$CONFIG_DIR"

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to check system requirements
check_requirements() {
    log "Checking system requirements..."
    
    local missing_tools=()
    
    # Check for required tools
    for tool in docker nmap dig jq nc; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log "❌ Missing required tools: ${missing_tools[*]}"
        log "Install with: sudo dnf install ${missing_tools[*]}"
        return 1
    fi
    
    # Check if PostgreSQL container is running
    if ! docker ps | grep -q "$DB_CONTAINER"; then
        log "❌ PostgreSQL container '$DB_CONTAINER' is not running"
        log "Start with: cd $SCRIPT_DIR && docker-compose -f docker-compose.monitoring.yml up -d postgres"
        return 1
    fi
    
    log "✅ All requirements met"
    return 0
}

# Function to run database-based discovery
run_database_discovery() {
    log "Running database-based server discovery..."
    
    if [ -f "$SCRIPT_DIR/test-targeted-discovery.sh" ]; then
        cd "$SCRIPT_DIR"
        ./test-targeted-discovery.sh > "$CONFIG_DIR/database-discovery.log" 2>&1
        
        if [ $? -eq 0 ]; then
            log "✅ Database discovery completed successfully"
            
            # Copy generated config
            if [ -f "/tmp/target_monitoring_config.json" ]; then
                cp "/tmp/target_monitoring_config.json" "$CONFIG_DIR/prometheus_targets_db.json"
                log "📁 Database discovery config saved to $CONFIG_DIR/prometheus_targets_db.json"
            fi
            
            return 0
        else
            log "❌ Database discovery failed"
            return 1
        fi
    else
        log "❌ Database discovery script not found"
        return 1
    fi
}

# Function to run network-based discovery (if available)
run_network_discovery() {
    log "Running network-based server discovery..."
    
    if [ -f "$SCRIPT_DIR/network-discovery.sh" ]; then
        cd "$SCRIPT_DIR"
        ./network-discovery.sh >> "$CONFIG_DIR/network-discovery.log" 2>&1
        
        if [ $? -eq 0 ]; then
            log "✅ Network discovery completed successfully"
            return 0
        else
            log "⚠️  Network discovery completed with warnings (check logs)"
            return 0  # Don't fail completely if network discovery has issues
        fi
    else
        log "ℹ️  Network discovery script not available - using database only"
        return 0
    fi
}

# Function to consolidate discovery results
consolidate_discovery_results() {
    log "Consolidating discovery results..."
    
    # Get current target servers from database
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
                'discovery_timestamp', extract(epoch from last_seen)::text,
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
        # Generate consolidated Prometheus configuration
        cat > "$CONFIG_DIR/prometheus_final_config.json" << EOF
{
  "job_name": "automated-infrastructure-monitoring",
  "honor_labels": true,
  "scrape_interval": "15s",
  "scrape_timeout": "10s",
  "metrics_path": "/metrics",
  "scheme": "http",
  "static_configs": $targets_json
}
EOF
        
        # Generate file service discovery format
        echo "$targets_json" | jq '.' > "$CONFIG_DIR/prometheus_file_sd_config.json"
        
        # Generate summary report
        local server_count
        server_count=$(echo "$targets_json" | jq '. | length' 2>/dev/null || echo "0")
        
        cat > "$CONFIG_DIR/discovery_summary.txt" << EOF
=== Server Discovery Summary ===
Discovery completed: $(date)
Target patterns: consul-monitoring-server, monitored-node-**

Discovered servers: $server_count

Configuration files generated:
• prometheus_final_config.json - Complete Prometheus job configuration
• prometheus_file_sd_config.json - File service discovery format
• discovery_summary.txt - This summary

Next steps:
1. Copy prometheus_final_config.json to your Prometheus configuration
2. Or use prometheus_file_sd_config.json for file-based service discovery
3. Restart Prometheus to apply new targets
4. Monitor logs for successful scraping

Discovery automation is running. Check $LOG_FILE for ongoing status.
EOF
        
        log "✅ Discovery consolidation complete"
        log "📊 Found $server_count target servers"
        log "📁 Final configurations available in $CONFIG_DIR/"
        
        return 0
    else
        log "❌ No target servers found during consolidation"
        return 1
    fi
}

# Function to validate discovered servers
validate_discovered_servers() {
    log "Validating discovered servers..."
    
    local validation_results=""
    local total_servers=0
    local reachable_servers=0
    
    # Get server list for validation
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
            
            total_servers=$((total_servers + 1))
            
            if timeout 5 nc -z "$ip" "$port" 2>/dev/null; then
                log "✅ $hostname ($ip:$port) - Reachable"
                reachable_servers=$((reachable_servers + 1))
                validation_results="${validation_results}✅ $hostname: Reachable\n"
            else
                log "❌ $hostname ($ip:$port) - Unreachable"
                validation_results="${validation_results}❌ $hostname: Unreachable\n"
            fi
        fi
    done
    
    # Save validation results
    echo -e "$validation_results" > "$CONFIG_DIR/server_validation.txt"
    
    log "Validation complete: Check $CONFIG_DIR/server_validation.txt for details"
}

# Function to setup complete automation
setup_complete_automation() {
    local script_path="$(realpath "$0")"
    
    log "Setting up complete discovery automation..."
    
    # Set up cron job for automated discovery every hour
    local cron_job="0 * * * * $script_path --automated >> $LOG_FILE 2>&1"
    
    (crontab -l 2>/dev/null | grep -v "$script_path"; echo "$cron_job") | crontab -
    
    log "✅ Automated discovery configured (every hour)"
    log "📅 Check $LOG_FILE for automated discovery logs"
    log "📁 Configurations will be updated in $CONFIG_DIR/"
}

# Function to show current status
show_current_status() {
    log "=== Current Infrastructure Status ==="
    
    # Show database status
    local db_status="❌ Disconnected"
    if docker exec "$DB_CONTAINER" psql -U monitoring -d monitoring -c "SELECT 1;" >/dev/null 2>&1; then
        db_status="✅ Connected"
    fi
    
    log "Database: $db_status"
    
    # Show discovered servers
    local server_count
    server_count=$(docker exec "$DB_CONTAINER" psql -U monitoring -d monitoring -t -c "
    SELECT COUNT(*) FROM servers 
    WHERE status = 'active' 
    AND (hostname LIKE 'monitored-node-%' OR hostname = 'consul-monitoring-server');
    " 2>/dev/null | tr -d '[:space:]' || echo "0")
    
    log "Target servers discovered: $server_count"
    
    # Show recent discoveries
    if [ "$server_count" -gt 0 ]; then
        log "Recent target servers:"
        docker exec "$DB_CONTAINER" psql -U monitoring -d monitoring -c "
        SELECT 
            hostname,
            host(ip_address) as ip,
            node_type,
            CASE 
                WHEN hostname = 'consul-monitoring-server' THEN '🖥️ Monitoring Server'
                WHEN hostname LIKE 'monitored-node-%' THEN '📡 Monitored Node'
                ELSE '❓ Other'
            END as role,
            last_seen
        FROM servers 
        WHERE status = 'active' 
        AND (hostname LIKE 'monitored-node-%' OR hostname = 'consul-monitoring-server')
        ORDER BY last_seen DESC;
        " 2>/dev/null
    fi
}

# Main execution function
main() {
    case "${1:-}" in
        --automated)
            log "=== Automated Discovery Run ==="
            
            if check_requirements; then
                run_database_discovery
                run_network_discovery
                consolidate_discovery_results
                validate_discovered_servers
                log "🎯 Automated discovery cycle complete"
            else
                log "❌ Automated discovery failed - requirements not met"
                exit 1
            fi
            ;;
            
        --setup-automation)
            setup_complete_automation
            ;;
            
        --status)
            show_current_status
            ;;
            
        --validate)
            if check_requirements; then
                validate_discovered_servers
            fi
            ;;
            
        *)
            echo "=== Comprehensive Server Discovery Automation ==="
            echo "Targeted patterns: consul-monitoring-server, monitored-node-**"
            echo ""
            echo "Usage:"
            echo "  $0                    - Run complete discovery cycle"
            echo "  $0 --setup-automation - Setup automated discovery (hourly)"
            echo "  $0 --status          - Show current infrastructure status"
            echo "  $0 --validate        - Validate discovered servers"
            echo "  $0 --automated       - Run automated discovery (for cron)"
            echo ""
            
            if check_requirements; then
                log "Running complete discovery cycle..."
                
                run_database_discovery
                run_network_discovery
                consolidate_discovery_results
                validate_discovered_servers
                
                echo ""
                log "🎯 Discovery cycle complete!"
                log "📁 Results available in: $CONFIG_DIR/"
                echo ""
                echo "Configuration files generated:"
                echo "• $CONFIG_DIR/prometheus_final_config.json"
                echo "• $CONFIG_DIR/prometheus_file_sd_config.json" 
                echo "• $CONFIG_DIR/discovery_summary.txt"
                echo ""
                echo "🔄 To setup automated discovery:"
                echo "   $0 --setup-automation"
            else
                exit 1
            fi
            ;;
    esac
}

# Execute main function
main "$@"
