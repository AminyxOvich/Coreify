-- Create database if it doesn't exist
CREATE DATABASE IF NOT EXISTS monitoring;

-- Connect to monitoring database
\c monitoring;

-- Create servers table for dynamic server discovery
CREATE TABLE IF NOT EXISTS servers (
    server_id SERIAL PRIMARY KEY,
    hostname VARCHAR(255) NOT NULL UNIQUE,
    ip_address INET NOT NULL,
    port INTEGER NOT NULL DEFAULT 22,
    status VARCHAR(50) DEFAULT 'unknown',
    server_type VARCHAR(100) DEFAULT 'linux',
    metadata JSONB DEFAULT '{}',
    last_discovered TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create index for faster queries
CREATE INDEX IF NOT EXISTS idx_servers_status ON servers(status);
CREATE INDEX IF NOT EXISTS idx_servers_type ON servers(server_type);
CREATE INDEX IF NOT EXISTS idx_servers_ip ON servers(ip_address);

-- Insert sample server data for testing
INSERT INTO servers (hostname, ip_address, port, status, server_type, metadata) VALUES
    ('web-server-01', '192.168.1.10', 80, 'active', 'web-server', '{"role": "frontend", "environment": "production"}'),
    ('db-server-01', '192.168.1.20', 5432, 'active', 'database', '{"role": "primary", "environment": "production"}'),
    ('api-server-01', '192.168.1.30', 8080, 'active', 'api-server', '{"role": "backend", "environment": "production"}'),
    ('cache-server-01', '192.168.1.40', 6379, 'active', 'cache', '{"role": "redis", "environment": "production"}'),
    ('monitor-server-01', '192.168.1.50', 9090, 'active', 'monitoring', '{"role": "prometheus", "environment": "production"}')
ON CONFLICT (hostname) DO UPDATE SET
    ip_address = EXCLUDED.ip_address,
    port = EXCLUDED.port,
    status = EXCLUDED.status,
    server_type = EXCLUDED.server_type,
    metadata = EXCLUDED.metadata,
    updated_at = CURRENT_TIMESTAMP;

-- Create function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Create trigger to automatically update updated_at
CREATE TRIGGER update_servers_updated_at 
    BEFORE UPDATE ON servers 
    FOR EACH ROW 
    EXECUTE FUNCTION update_updated_at_column();
