#!/bin/bash

# Network-based Server Discovery
# Discovers servers matching target patterns using network scanning
# Integrates with database for persistent storage

set -euo pipefail

# Configuration
NETWORK_RANGE="${NETWORK_RANGE:-192.168.112.0/24,192.168.1.0/24}"
DB_CONTAINER="monitoring-postgres"
DB_USER="monitoring"
DB_NAME="monitoring"
LOG_FILE="/var/log/discovery.log"

# Required ports for monitoring
NODE_EXPORTER_PORT=9100
CONSUL_PORT=8500

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to scan network for potential monitoring targets
scan_network_for_targets() {
    log "Scanning network $NETWORK_RANGE for target servers..."
    
    # Use nmap to discover hosts with node_exporter running
    local discovered_hosts=()
    
    # Scan for hosts with node_exporter port open - use -Pn to skip ping test (hosts may block ICMP)
    log "Scanning for hosts with node_exporter (port $NODE_EXPORTER_PORT) - using -Pn to skip ping test..."
    nmap -Pn -p $NODE_EXPORTER_PORT --open -T4 "$NETWORK_RANGE" 2>/dev/null | grep -E "^Nmap scan report for|$NODE_EXPORTER_PORT/tcp open" | while read -r line; do
        if [[ "$line" =~ ^Nmap\ scan\ report\ for\ (.+)$ ]]; then
            current_host="${BASH_REMATCH[1]}"
            
            # Debug output to see what nmap is finding
            log "DEBUG: Raw nmap host entry: $current_host"
            
            # If the entry contains an IP in parentheses (hostname (IP)), extract the IP
            if [[ "$current_host" =~ \(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\) ]]; then
                current_host="${BASH_REMATCH[1]}"
                log "DEBUG: Extracted IP from hostname: $current_host"
            # If entry is already just an IP address, keep it as is
            elif [[ "$current_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                log "DEBUG: Found direct IP: $current_host"
            # Otherwise try to clean up any other format
            else
                current_host=$(echo "$current_host" | sed -E 's/.*\(([0-9.]+)\).*/\1/' | sed 's/[()]//g')
                log "DEBUG: Cleaned host: $current_host"
            fi
        elif [[ "$line" =~ $NODE_EXPORTER_PORT/tcp\ open ]]; then
            if [ -n "$current_host" ]; then
                # Verify if we have a valid IP address format before returning it
                if [[ "$current_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    log "DEBUG: Valid IP found with node_exporter: $current_host"
                    echo "$current_host"
                else
                    log "DEBUG: Invalid IP format, skipping: $current_host"
                fi
            fi
        fi
    done
}

# Function to identify server type based on hostname/IP
identify_server_type() {
    local ip="$1"
    local hostname=""

    # Always try to get hostname from consul if port 8500 is open
    if timeout 3 nc -z "$ip" $CONSUL_PORT 2>/dev/null; then
        hostname=$(curl -s "http://$ip:$CONSUL_PORT/v1/agent/self" 2>/dev/null | jq -r '.Config.NodeName // empty' 2>/dev/null || echo "")
    fi

    # If still no hostname, use IP-based naming
    if [ -z "$hostname" ]; then
        hostname="discovered-host-$(echo "$ip" | tr '.' '-')"
    fi

    echo "$hostname"
}

# Function to determine if hostname matches target patterns
matches_target_patterns() {
    local hostname="$1"
    
    if [[ "$hostname" == "consul-monitoring-server" ]] || [[ "$hostname" =~ ^monitored-node- ]]; then
        return 0
    else
        return 1
    fi
}

# Function to validate server capabilities
validate_server_capabilities() {
    local ip="$1"
    local hostname="$2"
    
    local capabilities=()
    
    # Check node_exporter
    if timeout 5 curl -s "http://$ip:$NODE_EXPORTER_PORT/metrics" >/dev/null 2>&1; then
        capabilities+=("node_exporter")
    fi
    
    # Check consul
    if timeout 3 nc -z "$ip" $CONSUL_PORT 2>/dev/null; then
        capabilities+=("consul")
    fi
    
    # Determine node type based on capabilities and hostname
    local node_type="monitored"
    if [[ "$hostname" == "consul-monitoring-server" ]]; then
        node_type="monitoring-host"
    elif [[ "$hostname" =~ ^monitored-node- ]]; then
        node_type="monitored"
    fi
    
    echo "$node_type"
}

# Function to register discovered servers in database
register_discovered_servers() {
    local discoveries="$1"
    local registered_count=0
    
    log "Registering discovered servers in database..."
    
    while IFS='|' read -r ip hostname node_type; do
        if [ -n "$ip" ] && [ -n "$hostname" ]; then
            local server_id="$hostname"
            
            # Generate metadata
            local metadata=$(cat << EOF
{
    "discovery_method": "network_scan",
    "discovered_at": "$(date -u +"%Y-%m-%d %H:%M:%S")",
    "discovery_source": "nmap",
    "capabilities": ["node_exporter"]
}
EOF
)
            
            # Insert or update server in database
            docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "
            INSERT INTO servers (
                server_id, hostname, ip_address, salt_minion_id, 
                node_type, status, consul_registered, prometheus_enabled,
                node_exporter_port, metadata
            ) VALUES (
                '$server_id', '$hostname', '$ip', '$hostname',
                '$node_type', 'active', false, true,
                $NODE_EXPORTER_PORT, '$metadata'::jsonb
            )
            ON CONFLICT (server_id) DO UPDATE SET
                hostname = EXCLUDED.hostname,
                ip_address = EXCLUDED.ip_address,
                node_type = EXCLUDED.node_type,
                status = 'active',
                prometheus_enabled = true,
                metadata = EXCLUDED.metadata,
                updated_at = CURRENT_TIMESTAMP,
                last_seen = CURRENT_TIMESTAMP;
            " >/dev/null 2>&1
            
            if [ $? -eq 0 ]; then
                log "✅ Registered: $hostname ($ip) as $node_type"
                registered_count=$((registered_count + 1))
            else
                log "❌ Failed to register: $hostname ($ip)"
            fi
        fi
    done <<< "$discoveries"
    
    log "✅ Registered $registered_count target servers"
}

# Function to run complete network discovery
run_network_discovery() {
    log "=== Network-based Target Discovery ==="
    log "Scanning network: $NETWORK_RANGE"
    log "Target patterns: consul-monitoring-server, monitored-node-**"
    
    local discoveries=""
    local target_count=0
    
    # Scan network for hosts with node_exporter
    while read -r ip; do
        if [ -n "$ip" ]; then
            log "Found host with node_exporter: $ip"
            
            # Identify hostname and type
            local hostname
            hostname=$(identify_server_type "$ip")
            
            # Check if matches target patterns
            if matches_target_patterns "$hostname"; then
                local node_type
                node_type=$(validate_server_capabilities "$ip" "$hostname")
                
                discoveries="${discoveries}${ip}|${hostname}|${node_type}\n"
                target_count=$((target_count + 1))
                log "🎯 Target found: $hostname ($ip) - $node_type"
            else
                log "⏭️  Skipping: $hostname ($ip) - doesn't match target patterns"
            fi
        fi
    done < <(scan_network_for_targets)
    
    if [ $target_count -gt 0 ]; then
        log "Found $target_count target servers matching patterns"
        
        # Register discoveries in database
        register_discovered_servers "$(echo -e "$discoveries")"
        
        # Run the existing targeted discovery to generate configs
        log "Generating monitoring configurations..."
        /home/charon/Downloads/Monitoring_Stack/monitoring-host-system/test-targeted-discovery.sh >/dev/null 2>&1
        
        log "🎯 Network discovery complete!"
        log "📁 Updated configurations available in /tmp/"
        
        return 0
    else
        log "❌ No target servers found in network scan"
        return 1
    fi
}

# Function to setup automated network discovery
setup_automated_network_discovery() {
    local script_path="$(realpath "$0")"
    local cron_job="0 */2 * * * $script_path --automated >> $LOG_FILE 2>&1"
    
    log "Setting up automated network discovery (every 2 hours)..."
    (crontab -l 2>/dev/null | grep -v "$script_path"; echo "$cron_job") | crontab -
    
    log "✅ Automated network discovery configured"
    log "📅 Will run every 2 hours to discover new target servers"
}

# Main execution
main() {
    case "${1:-}" in
        --automated)
            log "Running automated network discovery..."
            run_network_discovery
            ;;
        --setup-automation)
            setup_automated_network_discovery
            ;;
        *)
            echo "=== Network-based Server Discovery ==="
            echo "Discovers servers matching patterns: consul-monitoring-server, monitored-node-**"
            echo ""
            
            # Check for required tools
            if ! command -v nmap >/dev/null 2>&1; then
                echo "❌ nmap is required but not installed. Install with: sudo dnf install nmap"
                exit 1
            fi
            
            if ! command -v dig >/dev/null 2>&1; then
                echo "❌ dig is required but not installed. Install with: sudo dnf install bind-utils"
                exit 1
            fi
            
            run_network_discovery
            
            echo ""
            echo "🔄 To set up automated network discovery every 2 hours:"
            echo "   $0 --setup-automation"
            ;;
    esac
}

# Handle command line arguments
main "$@"
