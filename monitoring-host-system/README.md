# Monitoring Host System

Central monitoring stack with **Consul, Prometheus, Grafana, Loki, Promtail, PostgreSQL, and n8n** for metrics collection, log aggregation, visualization, and self-healing automation.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│              Monitoring Host (Bridge Network)            │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────┐   ┌────────────┐   ┌──────────────┐  │
│  │ Consul Server│   │ Prometheus │   │   Grafana    │  │
│  │  (SD/KV)     │   │  (Metrics) │   │    (UI)      │  │
│  │  port 8500   │◄──┤  port 9090 │◄──┤  port 3000   │  │
│  └──────┬───────┘   └─────┬──────┘   └──────────────┘  │
│         │                 │                             │
│  ┌──────▼─────────────────▼──────────────────────────┐  │
│  │         PostgreSQL (Server Registry)             │  │
│  │              port 5432                            │  │
│  └───────────────────────────────────────────────────┘  │
│                                                          │
│  ┌──────────────┐   ┌────────────┐   ┌──────────────┐  │
│  │     Loki     │   │  Promtail  │   │     n8n      │  │
│  │    (Logs)    │◄──┤ (Shipping) │   │ (Workflow)   │  │
│  │  port 3100   │   │ port 9080  │   │  port 5678   │  │
│  └──────────────┘   └────────────┘   └──────────────┘  │
│         ▲                                                │
└─────────┼────────────────────────────────────────────────┘
          │
          │ Monitored Nodes send logs/metrics
          ▼
   [node-01] [node-02] [node-03] ...
```

**Network Mode:** All services use bridge networking with the `monitoring` named network.

---

## Prerequisites

- **OS:** Fedora 38+, RHEL 9+, CentOS Stream 9+, or compatible Linux
- **Docker:** Version 20.10+ with Compose v2
- **Firewall:** Ports 8500, 9090, 3000, 3100, 5432, 5678, 9100, 9080 open
- **SELinux:** Must allow container access to host ports and network
- **SaltStack Master:** Required for self-healing remediation (separate installation)

---

## Deployment Steps

### 1. Configure the OS (Run Once)

```bash
sudo ./setup-os.sh
```

**What it does:**
- ✅ Installs Docker CE, SELinux tools, PostgreSQL client, firewall utilities
- ✅ Configures Docker daemon with log rotation and ulimits
- ✅ Opens firewall ports: 8500 (Consul), 8600 DNS, 8300-8302 (Consul gossip), 9090 (Prometheus), 3000 (Grafana), 3100 (Loki), 5432 (PostgreSQL), 5678 (n8n), 9100/9080 (exporters)
- ✅ Compiles and installs SELinux policy (`monitoring_policy.te`) for container port binding and networking
- ✅ Sets SELinux booleans: `container_connect_any=1`, `container_manage_cgroup=1`, `httpd_can_network_connect=1`
- ✅ Tunes sysctl: TCP keepalive, high connection limits (somaxconn=65535), file descriptors (2M), memory overcommit
- ✅ Creates `loki` system user (UID 10001) for volume ownership
- ✅ Adds current user to `docker` group

**Reboot after first run** to apply kernel parameters.

---

### 2. Configure Environment Variables

```bash
cp .env.example .env
nano .env
```

**Required variables:**

| Variable | Example | Description |
|----------|---------|-------------|
| `GF_ADMIN_PASSWORD` | `securePassword123` | Grafana admin password |
| `POSTGRES_PASSWORD` | `dbPassword456` | PostgreSQL password |

---

### 3. Update Consul Server IP

Edit [config/consul-server.hcl](config/consul-server.hcl) and replace `YOUR_MONITORING_HOST_IP` with this machine's LAN IP:

```bash
nano config/consul-server.hcl
# Replace 192.168.1.100 with your monitoring host IP
```

---

### 4. Deploy the Stack

```bash
./deploy-monitoring.sh
```

**What it does:**
- Validates environment variables
- Checks OS setup completion
- Starts all 7 services with health checks
- Waits for Prometheus and Grafana to become healthy
- Displays access URLs

---

## Services

### Consul Server

- **Image:** `hashicorp/consul:1.16`
- **Purpose:** Service discovery, health checks, distributed KV store
- **Ports:** 8500 (HTTP API), 8600 (DNS), 8300-8302 (LAN/WAN gossip)
- **Config:** [config/consul-server.hcl](config/consul-server.hcl)
- **Healthcheck:** `consul members` (every 30s)
- **Resource Limits:** 512M memory, 0.5 CPU

### Prometheus

- **Image:** `prom/prometheus:v2.53.4`
- **Purpose:** Metrics collection and alerting
- **Ports:** 9090 (Web UI + API)
- **Config:** [config/prometheus.yml](config/prometheus.yml)
- **Alerting Rules:** [config/consul-rules.yml](config/consul-rules.yml) (HighCPULoad,  HighMemoryUsage, DiskSpaceLow, NodeDown)
- **Healthcheck:** `wget -qO- http://localhost:9090/-/healthy`
- **Resource Limits:** 2G memory, 1.0 CPU
- **Scrape Targets:**
  - Consul SD (auto-discovers monitored nodes)
  - File SD ([config/prometheus_file_sd.json](config/prometheus_file_sd.json) for static targets)
  - Self-monitoring (Prometheus, Grafana, Loki)

### Grafana

- **Image:** `grafana/grafana:11.5.2`
- **Purpose:** Visualization and dashboards
- **Ports:** 3000 (Web UI)
- **Healthcheck:** `curl -f http://localhost:3000/api/health`
- **Resource Limits:** 512M memory, 0.5 CPU
- **Provisioned Datasources:** [config/grafana/provisioning/datasources/datasources.yml](config/grafana/provisioning/datasources/datasources.yml)
  - Prometheus (http://prometheus:9090)
  - Loki (http://loki:3100)
- **Default Credentials:** `admin` / `${GF_ADMIN_PASSWORD}`

### Loki

- **Image:** `grafana/loki:3.4.2`
- **Purpose:** Log aggregation (receives logs from Promtail on all nodes)
- **Ports:** 3100 (HTTP API)
- **Config:** [config/loki.yml](config/loki.yml) (TSDB schema v13, 14-day retention)
- **Healthcheck:** `wget -qO- http://localhost:3100/ready`
- **Resource Limits:** 1G memory, 0.5 CPU
- **Storage:** Named volume `monitoring_loki_data`

### Promtail (Host Logs)

- **Image:** `grafana/promtail:3.4.2`
- **Purpose:** Ship monitoring host's own logs to Loki
- **Ports:** 9080 (HTTP)
- **Config:** [config/promtail.yml](config/promtail.yml)
- **Volumes:** `/var/log:/var/log:ro`
- **Resource Limits:** 256M memory, 0.25 CPU

### PostgreSQL

- **Image:** `postgres:16-alpine`
- **Purpose:** Server registry, metrics history, alert tracking
- **Ports:** 5432
- **Database:** `monitoring`
- **Schema:** [config/init-postgres.sql](config/init-postgres.sql) (servers, server_metrics, server_alerts, server_logs tables)
- **Enhanced Schema:** [config/setup_enhanced_database.sql](config/setup_enhanced_database.sql) (n8n workflow integration)
- **Healthcheck:** `pg_isready -U monitoring`
- **Resource Limits:** 512M memory, 0.5 CPU

### n8n (Optional - for self-healing)

- **Image:** `n8nio/n8n:latest`
- **Purpose:** Self-healing workflow orchestration
- **Ports:** 5678 (Web UI)
- **Workflow:** [../anomaly_workflow_with_fallback.json](../anomaly_workflow_with_fallback.json) (import via UI)
- **Environment:** `N8N_BASIC_AUTH_ACTIVE=false`
- **Resource Limits:** 512M memory, 0.5 CPU

---

## Configuration Files

### Consul Server Configuration

**File:** [config/consul-server.hcl](config/consul-server.hcl)

- Registers 6 services: consul, prometheus, grafana, loki, node-exporter, promtail
- Sets up health checks for each service
- Enables Prometheus telemetry on port 9107

### Prometheus Scrape Configuration

**File:** [config/prometheus.yml](config/prometheus.yml)

- **Consul SD:** Auto-discovers services registered in Consul
- **File SD:** Static targets from [config/prometheus_file_sd.json](config/prometheus_file_sd.json)
- **Static Jobs:** prometheus, grafana, loki, consul, node-exporter

### Prometheus Alerting Rules

**File:** [config/consul-rules.yml](config/consul-rules.yml)

- `HighCPULoad`: CPU > 85% for 5 minutes
- `HighMemoryUsage`: Memory > 90% for 5 minutes
- `DiskSpaceLow`: Disk usage > 85%
- `NodeDown`: Instance unreachable for 5 minutes

### Loki Storage Configuration

**File:** [config/loki.yml](config/loki.yml)

- **Schema:** TSDB v13 (Loki 3.x compatible)
- **Retention:** 14 days (336 hours)
- **Storage:** Filesystem at `/loki`
- **Limits:** 5MB per stream, 15MB ingestion burst

### PostgreSQL Schema

**File:** [config/init-postgres.sql](config/init-postgres.sql)

Tables:
- `servers`: Server inventory (hostname, IP, salt_minion_id, node_type, consul_registered, prometheus_enabled)
- `server_metrics`: Metrics history (cpu_percent, memory_percent, disk_used_percent, threshold_exceeded)
- `server_alerts`: Alert tracking (alert_name, severity, status, prometheus_labels)
- `server_logs`: Log storage (message, log_level, source, archived)

**File:** [config/setup_enhanced_database.sql](config/setup_enhanced_database.sql)

Enhancements for n8n workflow:
- Alert suppression rules
- Maintenance mode windows
- Remediation action history

---

## Discovery System

The monitoring host includes automated infrastructure discovery scripts:

### infrastructure-discovery.sh

Full infrastructure scan combining network and infrastructure discovery:

```bash
./infrastructure-discovery.sh
```

Features:
- Network scanning (nmap)
- Service detection (SSH, HTTP, Docker)
- OS fingerprinting
- Auto-registration in Consul and PostgreSQL database
- JSON output for n8n workflow integration

### network-discovery.sh

Network-based discovery (ping sweep + port scanning):

```bash
./network-discovery.sh
```

### discovery-automation.sh

Scheduled discovery pipeline (run via cron):

```bash
./discovery-automation.sh
```

### Test Scripts

- `test-complete-workflow.sh`: Full discovery → registration → scraping test
- `test-dynamic-discovery.sh`: Consul service discovery test
- `test-targeted-discovery.sh`: Single node discovery

See [DISCOVERY_SYSTEM_COMPLETE.md](DISCOVERY_SYSTEM_COMPLETE.md) for full documentation.

---

## Database Setup

### Load Base Schema (Automatic on First Start)

The [config/init-postgres.sql](config/init-postgres.sql) schema is automatically loaded when PostgreSQL starts for the first time.

### Load Enhanced Schema (Manual - for n8n Workflow)

```bash
docker exec -i monitoring-postgres psql -U monitoring -d monitoring \
  < config/setup_enhanced_database.sql
```

This adds alert history tracking and maintenance mode features.

---

## Verification

### Check All Services

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

All 7 containers should show "Up" with "(healthy)" status.

### Access UIs

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://localhost:3000 | admin / ${GF_ADMIN_PASSWORD} |
| Prometheus | http://localhost:9090 | None |
| Consul | http://localhost:8500 | None |
| n8n | http://localhost:5678 | None (basic auth disabled) |

### Check Prometheus Targets

Visit http://localhost:9090/targets - you should see:
- Consul SD targets (monitored nodes)
- Static targets (monitoring host services)

### Query Metrics

```bash
curl -G 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=up' | jq
```

### Query Logs

```bash
curl -G 'http://localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query={job="system_logs"}' | jq
```

### Check Database

```bash
docker exec -it monitoring-postgres psql -U monitoring -d monitoring \
  -c "SELECT * FROM servers;"
```

---

## Troubleshooting

### Service won't start

1. **Check logs:**
   ```bash
   docker logs <service-name>
   ```

2. **Check healthcheck:**
   ```bash
   docker inspect <service-name> | jq '.[0].State.Health'
   ```

### Prometheus can't scrape targets

1. **Check firewall on monitored nodes:**
   ```bash
   sudo firewall-cmd --list-all
   ```

2. **Check Consul service registration:**
   ```bash
   curl http://localhost:8500/v1/catalog/services | jq
   ```

### Grafana datasources not auto-provisioned

1. **Check provisioning directory mount:**
   ```bash
   docker exec monitoring-grafana ls /etc/grafana/provisioning/datasources/
   ```
   Should show `datasources.yml`.

2. **Restart Grafana:**
   ```bash
   docker restart monitoring-grafana
   ```

### PostgreSQL schema not loaded

1. **Check init script execution:**
   ```bash
   docker logs monitoring-postgres | grep "init-postgres.sql"
   ```

2. **Manually load schema:**
   ```bash
   docker exec -i monitoring-postgres psql -U monitoring -d monitoring \
     < config/init-postgres.sql
   ```

### High resource usage

Adjust resource limits in [docker-compose.monitoring.yml](docker-compose.monitoring.yml):

```yaml
deploy:
  resources:
    limits:
      memory: 1G     # Reduce from 2G
      cpus: "0.5"    # Reduce from 1.0
```

---

## Files Reference

| File | Purpose |
|------|---------|
| [docker-compose.monitoring.yml](docker-compose.monitoring.yml) | Main stack definition (7 services) |
| [deploy-monitoring.sh](deploy-monitoring.sh) | Deployment script with health checks |
| [setup-os.sh](setup-os.sh) | One-time OS configuration |
| [monitoring_policy.te](monitoring_policy.te) | SELinux policy (v1.1) |
| [.env.example](.env.example) | Environment variable template |
| [config/consul-server.hcl](config/consul-server.hcl) | Consul server + service registrations |
| [config/prometheus.yml](config/prometheus.yml) | Prometheus scrape config |
| [config/consul-rules.yml](config/consul-rules.yml) | Prometheus alerting rules |
| [config/loki.yml](config/loki.yml) | Loki storage (TSDB v13) |
| [config/promtail.yml](config/promtail.yml) | Promtail config for host logs |
| [config/prometheus_file_sd.json](config/prometheus_file_sd.json) | Static file service discovery |
| [config/init-postgres.sql](config/init-postgres.sql) | PostgreSQL base schema |
| [config/setup_enhanced_database.sql](config/setup_enhanced_database.sql) | n8n workflow enhancements |
| [config/grafana/provisioning/datasources/datasources.yml](config/grafana/provisioning/datasources/datasources.yml) | Auto-configured datasources |
| [infrastructure-discovery.sh](infrastructure-discovery.sh) | Full infrastructure scanner |
| [network-discovery.sh](network-discovery.sh) | Network-based discovery |
| [discovery-automation.sh](discovery-automation.sh) | Scheduled discovery pipeline |
| [System Prompt.md](System%20Prompt.md) | n8n AI Agent system prompt |
| [DISCOVERY_SYSTEM_COMPLETE.md](DISCOVERY_SYSTEM_COMPLETE.md) | Discovery documentation |

---

## Integration with n8n Self-Healing Workflow

1. **Import workflow:** Load [../anomaly_workflow_with_fallback.json](../anomaly_workflow_with_fallback.json) into n8n UI
2. **Configure credentials:**
   - PostgreSQL: `localhost:5432`, user `monitoring`, database `monitoring`
   - SaltStack: Master IP and auth credentials
   - Clevify: API key for human approval
3. **Activate workflow:** Toggle to "Active" in n8n
4. **Test alert:** Trigger `HighCPULoad` alert in Prometheus to test workflow execution
