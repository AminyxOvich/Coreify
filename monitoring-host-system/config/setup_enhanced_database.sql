-- Enhanced Metrics Workflow Database Setup
-- Creates necessary tables for alerting and suppression features

-- Note: Execution log table removed since we no longer track last execution times
-- The enhanced workflow now runs directly on schedule without overlap prevention

-- Table to track alert history and implement suppression
CREATE TABLE IF NOT EXISTS alert_history (
    id SERIAL PRIMARY KEY,
    server_id VARCHAR(255) NOT NULL,
    alert_type VARCHAR(100) NOT NULL,
    last_sent TIMESTAMP WITH TIME ZONE NOT NULL,
    suppressed BOOLEAN DEFAULT FALSE,
    suppression_reason TEXT,
    severity VARCHAR(20) DEFAULT 'MEDIUM',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(server_id, alert_type)
);

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_alert_history_server_id ON alert_history(server_id);
CREATE INDEX IF NOT EXISTS idx_alert_history_last_sent ON alert_history(last_sent);
CREATE INDEX IF NOT EXISTS idx_alert_history_suppressed ON alert_history(suppressed);

-- Add maintenance mode flag to servers table if it doesn't exist
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'servers' AND column_name = 'maintenance_mode') THEN
        ALTER TABLE servers ADD COLUMN maintenance_mode BOOLEAN DEFAULT FALSE;
    END IF;
END $$;

DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'servers' AND column_name = 'maintenance_until') THEN
        ALTER TABLE servers ADD COLUMN maintenance_until TIMESTAMP WITH TIME ZONE;
    END IF;
END $$;

-- Create index for maintenance mode queries
CREATE INDEX IF NOT EXISTS idx_servers_maintenance ON servers(maintenance_mode);

-- Comments on tables
COMMENT ON TABLE alert_history IS 'Tracks alert history for suppression and escalation logic';
COMMENT ON COLUMN servers.maintenance_mode IS 'Flag to suppress alerts during maintenance';
COMMENT ON COLUMN servers.maintenance_until IS 'End time for maintenance mode';

-- Sample maintenance mode functions
CREATE OR REPLACE FUNCTION set_maintenance_mode(server_name VARCHAR, duration_hours INTEGER DEFAULT 2)
RETURNS VOID AS $$
BEGIN
    UPDATE servers 
    SET maintenance_mode = TRUE,
        maintenance_until = NOW() + (duration_hours || ' hours')::INTERVAL
    WHERE hostname = server_name;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION clear_expired_maintenance()
RETURNS VOID AS $$
BEGIN
    UPDATE servers 
    SET maintenance_mode = FALSE,
        maintenance_until = NULL
    WHERE maintenance_mode = TRUE 
    AND maintenance_until < NOW();
END;
$$ LANGUAGE plpgsql;

-- View for alert dashboard
CREATE OR REPLACE VIEW alert_summary AS
SELECT 
    s.hostname,
    s.ip_address,
    s.status,
    s.maintenance_mode,
    ah.alert_type,
    ah.last_sent,
    ah.suppressed,
    ah.severity,
    CASE 
        WHEN s.maintenance_mode THEN 'Maintenance Mode'
        WHEN ah.suppressed THEN 'Suppressed'
        WHEN ah.last_sent > NOW() - INTERVAL '1 hour' THEN 'Recent Alert'
        ELSE 'Normal'
    END as alert_status
FROM servers s
LEFT JOIN alert_history ah ON s.server_id = ah.server_id
WHERE s.prometheus_enabled = true
ORDER BY ah.last_sent DESC NULLS LAST;

COMMENT ON VIEW alert_summary IS 'Summary view of server alert status for dashboard';

-- Sample data for testing
DO $$
BEGIN
    -- Only insert if the table is empty
    IF NOT EXISTS (SELECT 1 FROM alert_history LIMIT 1) THEN
        INSERT INTO alert_history (server_id, alert_type, last_sent, suppressed, severity)
        VALUES 
        ('test-server', 'critical_threshold', NOW() - INTERVAL '2 hours', FALSE, 'HIGH'),
        ('test-server-2', 'critical_threshold', NOW() - INTERVAL '30 minutes', TRUE, 'MEDIUM');
    END IF;
END $$;

-- Function to check if alerts should be suppressed
CREATE OR REPLACE FUNCTION should_suppress_alert(server_name VARCHAR, alert_type_param VARCHAR)
RETURNS BOOLEAN AS $$
DECLARE
    is_suppressed BOOLEAN DEFAULT FALSE;
    in_maintenance BOOLEAN DEFAULT FALSE;
    recent_alert BOOLEAN DEFAULT FALSE;
BEGIN
    -- Check if server is in maintenance mode
    SELECT maintenance_mode INTO in_maintenance
    FROM servers 
    WHERE hostname = server_name;
    
    -- Check if there was a recent alert (within last hour)
    SELECT EXISTS(
        SELECT 1 FROM alert_history ah
        JOIN servers s ON ah.server_id = s.server_id
        WHERE s.hostname = server_name 
        AND ah.alert_type = alert_type_param
        AND ah.last_sent > NOW() - INTERVAL '1 hour'
        AND NOT ah.suppressed
    ) INTO recent_alert;
    
    -- Return TRUE if should suppress (maintenance mode OR recent alert)
    RETURN (in_maintenance OR recent_alert);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION should_suppress_alert IS 'Determines if an alert should be suppressed based on maintenance mode and recent alert history';

COMMIT;
