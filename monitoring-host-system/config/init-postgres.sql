-- Monitoring System Database Schema
-- Server Registry and Dynamic Discovery

-- Create servers table for dynamic server discovery
CREATE TABLE IF NOT EXISTS servers (
    id SERIAL PRIMARY KEY,
    server_id VARCHAR(255) UNIQUE NOT NULL,
    hostname VARCHAR(255) NOT NULL,
    ip_address INET NOT NULL,
    salt_minion_id VARCHAR(255),
    node_type VARCHAR(100) DEFAULT 'monitored',
    status VARCHAR(50) DEFAULT 'active',
    consul_registered BOOLEAN DEFAULT false,
    prometheus_enabled BOOLEAN DEFAULT true,
    node_exporter_port INTEGER DEFAULT 9100,
    tags JSONB DEFAULT '[]'::jsonb,
    metadata JSONB DEFAULT '{}'::jsonb,
    last_seen TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create index for faster lookups
CREATE INDEX IF NOT EXISTS idx_servers_ip_address ON servers(ip_address);
CREATE INDEX IF NOT EXISTS idx_servers_hostname ON servers(hostname);
CREATE INDEX IF NOT EXISTS idx_servers_salt_minion_id ON servers(salt_minion_id);
CREATE INDEX IF NOT EXISTS idx_servers_status ON servers(status);

-- Create server_metrics table for storing current metrics
CREATE TABLE IF NOT EXISTS server_metrics (
    id SERIAL PRIMARY KEY,
    server_id VARCHAR(255) REFERENCES servers(server_id) ON DELETE CASCADE,
    metric_name VARCHAR(100) NOT NULL,
    metric_value DECIMAL(10,4) NOT NULL,
    threshold_value DECIMAL(10,4),
    threshold_exceeded BOOLEAN DEFAULT false,
    severity VARCHAR(20) DEFAULT 'info',
    collected_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create index for metrics queries
CREATE INDEX IF NOT EXISTS idx_server_metrics_server_id ON server_metrics(server_id);
CREATE INDEX IF NOT EXISTS idx_server_metrics_collected_at ON server_metrics(collected_at);
CREATE INDEX IF NOT EXISTS idx_server_metrics_threshold_exceeded ON server_metrics(threshold_exceeded);

-- Create server_alerts table for alert history
CREATE TABLE IF NOT EXISTS server_alerts (
    id SERIAL PRIMARY KEY,
    server_id VARCHAR(255) REFERENCES servers(server_id) ON DELETE CASCADE,
    alert_type VARCHAR(100) NOT NULL,
    severity VARCHAR(20) NOT NULL,
    message TEXT NOT NULL,
    metrics_data JSONB,
    context_data JSONB,
    resolved BOOLEAN DEFAULT false,
    resolved_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create index for alerts queries
CREATE INDEX IF NOT EXISTS idx_server_alerts_server_id ON server_alerts(server_id);
CREATE INDEX IF NOT EXISTS idx_server_alerts_severity ON server_alerts(severity);
CREATE INDEX IF NOT EXISTS idx_server_alerts_resolved ON server_alerts(resolved);
CREATE INDEX IF NOT EXISTS idx_server_alerts_created_at ON server_alerts(created_at);

-- Create server_logs table for log storage and archiving
CREATE TABLE IF NOT EXISTS server_logs (
    id SERIAL PRIMARY KEY,
    server_id VARCHAR(255) REFERENCES servers(server_id) ON DELETE CASCADE,
    log_level VARCHAR(20) DEFAULT 'INFO',
    log_message TEXT NOT NULL,
    source VARCHAR(255),
    archived BOOLEAN DEFAULT false,
    collected_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for efficient log queries
CREATE INDEX IF NOT EXISTS idx_server_logs_server_id ON server_logs(server_id);
CREATE INDEX IF NOT EXISTS idx_server_logs_collected_at ON server_logs(collected_at);
CREATE INDEX IF NOT EXISTS idx_server_logs_archived ON server_logs(archived);
CREATE INDEX IF NOT EXISTS idx_server_logs_level ON server_logs(log_level);

-- Insert default monitored servers (existing ones from static config)
INSERT INTO servers (server_id, hostname, ip_address, salt_minion_id, node_type, status, consul_registered, metadata) 
VALUES 
    ('monitoring-server', 'consul-monitoring-server', '192.168.100.169', 'consul-monitoring-server', 'monitoring-host', 'active', true, '{"role": "monitoring", "services": ["consul", "prometheus", "grafana", "loki"]}'),
    ('monitored-node-01', 'monitored-node-01', '192.168.100.200', 'monitored-node-01', 'monitored', 'active', true, '{"role": "worker", "services": ["consul-agent", "node-exporter", "promtail"]}')
ON CONFLICT (server_id) DO UPDATE SET
    hostname = EXCLUDED.hostname,
    ip_address = EXCLUDED.ip_address,
    salt_minion_id = EXCLUDED.salt_minion_id,
    node_type = EXCLUDED.node_type,
    status = EXCLUDED.status,
    consul_registered = EXCLUDED.consul_registered,
    metadata = EXCLUDED.metadata,
    updated_at = CURRENT_TIMESTAMP;

-- Create function to update last_seen timestamp
CREATE OR REPLACE FUNCTION update_server_last_seen()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for automatic timestamp updates
DROP TRIGGER IF EXISTS trigger_update_servers_timestamp ON servers;
CREATE TRIGGER trigger_update_servers_timestamp
    BEFORE UPDATE ON servers
    FOR EACH ROW
    EXECUTE FUNCTION update_server_last_seen();

-- Create view for active servers with recent metrics
CREATE OR REPLACE VIEW active_servers_with_metrics AS
SELECT 
    s.server_id,
    s.hostname,
    s.ip_address,
    s.salt_minion_id,
    s.node_type,
    s.status,
    s.consul_registered,
    s.prometheus_enabled,
    s.node_exporter_port,
    s.tags,
    s.metadata,
    s.last_seen,
    COUNT(CASE WHEN sm.threshold_exceeded = true THEN 1 END) as active_alerts,
    MAX(sm.collected_at) as last_metric_collection
FROM servers s
LEFT JOIN server_metrics sm ON s.server_id = sm.server_id 
    AND sm.collected_at > CURRENT_TIMESTAMP - INTERVAL '1 hour'
WHERE s.status = 'active'
GROUP BY s.server_id, s.hostname, s.ip_address, s.salt_minion_id, s.node_type, 
         s.status, s.consul_registered, s.prometheus_enabled, s.node_exporter_port, 
         s.tags, s.metadata, s.last_seen;

-- Grant permissions
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO monitoring;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO monitoring;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO monitoring;

-- Create user for N8N access
CREATE USER n8n_user WITH PASSWORD 'n8n_monitoring_pass';
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO n8n_user;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO n8n_user;
