# 🖥️ Linux Server Monitoring & Self-Healing Stack

A production-ready, fully automated monitoring and **self-healing** system for Linux servers (Fedora / RHEL-based). It collects logs and metrics, detects anomalies via an AI API, generates SaltStack remediation commands, routes them through a human-approval gate (Clevify), and executes fixes automatically — all orchestrated by **n8n**.

---

## 📐 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        MONITORED NODES                                  │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  Consul Agent  │  Node Exporter (:9100)  │  Promtail (:9080)    │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                         (docker-compose.yml)                             │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │  metrics + logs
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                       MONITORING HOST                                   │
│                                                                         │
│  ┌────────────┐  ┌────────────┐  ┌─────────┐  ┌────────────────────┐  │
│  │  Consul    │  │ Prometheus │  │  Loki   │  │     Grafana        │  │
│  │  Server   │  │  (:9090)   │  │ (:3100) │  │     (:3000)        │  │
│  │  (:8500)  │  └─────┬──────┘  └────┬────┘  └────────────────────┘  │
│  └────────────┘        │              │                                 │
│         ▲  service     │              │ logs                            │
│         │  discovery   ▼              ▼                                 │
│         └──────── n8n Workflow Engine ──────────────────────────────┐  │
│                        (:5678)                                       │  │
│                                                                      │  │
│  ┌────────────────────────────────────────────────────────────────┐  │  │
│  │              SELF-HEALING WORKFLOW (n8n)                       │  │  │
│  │                                                                │  │  │
│  │  Scheduler → Loki Query → Collect Metrics → Split by Server   │  │  │
│  │      → Format Logs → Batch → Anomaly API (:5000)              │  │  │
│  │             ↓ (on API failure)                                 │  │  │
│  │      Generate Fallback Anomaly Data                            │  │  │
│  │             ↓                                                  │  │  │
│  │      Process Results → Command Generation Agent                │  │  │
│  │             ↓                                                  │  │  │
│  │      Request Approval (Clevify :3005)                          │  │  │
│  │             ↓  (on approval)                                   │  │  │
│  │      SaltStack Execution → Healing Agent                       │  │  │
│  └────────────────────────────────────────────────────────────────┘  │  │
│                                                                      │  │
│  ┌────────────┐  ┌─────────────────┐  ┌──────────────────────────┐  │  │
│  │ PostgreSQL │  │  Anomaly API    │  │  Clevify Approval UI     │  │  │
│  │  (:5432)  │  │  (:5000)        │  │  (:3005)                 │  │  │
│  └────────────┘  └─────────────────┘  └──────────────────────────┘  │  │
└──────────────────────────────────────────────────────────────────────────┘
                               │  SaltStack commands
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    SaltStack Master                                      │
│         salt 'monitored-node-*' <module>.<function> <args>              │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 🗂️ Repository Structure

```
Monitoring_Stack/
├── anomaly_workflow_with_fallback.json   # Main n8n workflow (import this)
├── setup_enhanced_database.sql          # PostgreSQL schema for server registry
├── docker-compoose-monitored-in-node-02.yml  # Alt compose for node-02
├── prontail-config-monitored-in-node-02.yml  # Promtail config for node-02
├── LICENSE
│
├── monitored-system/                    # Deploy on EACH monitored node
│   ├── docker-compose.yml
│   ├── Dockerfile                       # Custom Consul agent image
│   ├── .env.example                     # ← Copy to .env and fill in IPs
│   ├── consul/
│   │   ├── consul.hcl.template          # Consul agent config (uses env vars)
│   │   └── entrypoint.sh
│   ├── node-exporter/
│   │   └── entrypoint.sh
│   ├── promtail/
│   │   └── config.yml
│   └── scripts/
│       ├── deploy.sh
│       └── teardown.sh
│
└── monitoring-host-system/              # Deploy on the MONITORING HOST
    ├── docker-compose.monitoring.yml
    ├── .env.example                     # ← Copy to .env and fill in secrets
    ├── deploy-monitoring.sh
    ├── init-db.sql
    ├── System Prompt.md                 # n8n AI Agent system prompt
    ├── DISCOVERY_SYSTEM_COMPLETE.md     # Discovery system documentation
    └── config/
        ├── consul-server.hcl            # Consul server config
        ├── prometheus.yml               # Prometheus scrape config
        ├── consul-rules.yml             # Prometheus alerting rules
        ├── loki.yml                     # Loki storage config
        ├── promtail.yml                 # Promtail for monitoring host logs
        ├── promtail-agent.yml           # Promtail agent config template
        └── prometheus_file_sd.json      # Static file SD targets (edit IPs)
```

---

## 🚀 Quick Start

### Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Docker + Docker Compose | v2+ | Run all services |
| n8n | latest | Workflow orchestration |
| SaltStack | 3006+ | Remote command execution |
| Python 3 | 3.9+ | Anomaly detection API |
| Clevify | latest | Human-in-the-loop approval |

---

### 1. Deploy the Monitoring Host

```bash
cd monitoring-host-system

# Configure secrets
cp .env.example .env
nano .env   # Set GF_ADMIN_PASSWORD, POSTGRES_PASSWORD

# Edit consul-server.hcl — replace YOUR_MONITORING_HOST_IP with your LAN IP
nano config/consul-server.hcl

# Edit prometheus_file_sd.json — replace placeholder IPs with real node IPs
nano config/prometheus_file_sd.json

# Launch all services (Consul, Prometheus, Grafana, Loki, Promtail, PostgreSQL)
./deploy-monitoring.sh
```

Services will be available at:
| Service | URL | Default Credentials |
|---------|-----|---------------------|
| Grafana | http://localhost:3000 | admin / (from .env) |
| Prometheus | http://localhost:9090 | — |
| Loki | http://localhost:3100 | — |
| Consul UI | http://localhost:8500 | — |
| PostgreSQL | localhost:5432 | (from .env) |

---

### 2. Deploy on Each Monitored Node

```bash
cd monitored-system

# Configure environment
cp .env.example .env
nano .env   # Set MONITORING_HOST, CONSUL_NODE_NAME, CONSUL_ADVERTISE

# Build and start (Consul Agent, Node Exporter, Promtail)
./scripts/deploy.sh
```

> **Naming convention:** Set `CONSUL_NODE_NAME` to `monitored-node-01`, `monitored-node-02`, etc. The self-healing workflow uses this pattern to target SaltStack minions.

---

### 3. Set Up the Database

```bash
# On the monitoring host, load the enhanced schema
docker exec -i monitoring-postgres psql -U monitoring -d monitoring \
  < setup_enhanced_database.sql
```

---

### 4. Import the n8n Workflow

1. Open n8n → **Workflows** → **Import from file**
2. Select `anomaly_workflow_with_fallback.json`
3. Configure credentials:
   - **Loki**: point to `http://localhost:3100`
   - **Anomaly API**: `http://localhost:5000` (your detection service)
   - **Clevify**: `http://localhost:3005/api/request-approval`
4. Activate the workflow

---

## 🔄 Self-Healing Workflow — Step by Step

| Step | n8n Node | Description |
|------|----------|-------------|
| 1 | **Scheduler** | Triggers every N minutes |
| 2 | **HTTP Request (Loki)** | Queries recent logs from all monitored nodes |
| 3 | **Collect Server Metrics** | Pulls CPU/memory/disk from Prometheus |
| 4 | **Split by Server** | Fans out one item per node |
| 5 | **Format for Anomaly Detection** | Structures log data for the AI API |
| 6 | **Batch Logs** | Groups data for efficient API calls |
| 7 | **Call Anomaly Detection API** | POST to `:5000/detect` — returns anomaly scores |
| 7a | **Generate Fallback Anomaly Data** | If API fails, injects realistic firewall-block logs for `monitored-node-02` |
| 8 | **Process Anomaly Results** | Filters events above threshold |
| 9 | **Command Generation Agent** | Extracts minion names, builds SaltStack commands + `toolParams` |
| 10 | **Request Approval (Clevify)** | Sends commands for human review via `POST /api/request-approval` |
| 11 | **Execute via SaltStack** | On approval: `salt 'monitored-node-XX' <module>.<function> <args>` |
| 12 | **Send Firewall Alert** | Notifies team of applied fix |

### Approval Payload Format

```json
{
  "agentId": "healing-agent-001",
  "toolName": "saltstack",
  "toolParams": {
    "module": "firewalld",
    "function": "add_port",
    "arguments": ["8000/tcp"],
    "target": "monitored-node-02"
  },
  "commands": [
    {
      "command": "salt 'monitored-node-02' firewalld.add_port '8000/tcp'",
      "description": "Open port 8000/tcp blocked by firewalld/SELinux on monitored-node-02",
      "risk_level": "medium"
    }
  ],
  "risk_level": "medium",
  "analysis": "Firewall blocking port 8000 detected in /var/log/audit/audit.log"
}
```

---

## 🧂 SaltStack Setup

SaltStack is used to apply remediation commands to minions (monitored nodes).

### Master configuration

Ensure your `/etc/salt/master` includes:
```yaml
publisher_acl:
  healing-agent:
    - '*':
      - cmd.run
      - firewalld.*
      - service.*
      - pkg.*
```

### Verify connectivity

```bash
# On the Salt master
sudo salt '*' test.ping
sudo salt 'monitored-node-01' grains.item os
```

---

## 🔍 Dynamic Server Discovery

The `monitoring-host-system/` includes a complete **database-driven discovery** system:

```bash
# Scan network and register new nodes
./network-discovery.sh

# Run full infrastructure discovery
./infrastructure-discovery.sh

# Test discovery targeting
./test-targeted-discovery.sh
```

Discovery uses a PostgreSQL table with pattern matching:
```sql
WHERE hostname LIKE 'monitored-node-%'
   OR hostname = 'consul-monitoring-server'
```

---

## 📊 Grafana Dashboards

After deployment, add Loki and Prometheus as data sources in Grafana:

- **Prometheus**: `http://prometheus:9090`
- **Loki**: `http://loki:3100`

Recommended dashboards to import from grafana.com:
- Node Exporter Full: `1860`
- Loki / Promtail: `13639`
- Consul: `10642`

---

## 🔒 Security Notes

- **Never commit `.env` files** — always use `.env.example` as a template
- **Grafana & PostgreSQL passwords** are read from environment variables
- **Consul advertise IPs** should be your private LAN IPs only
- **SaltStack ACL** restricts healing-agent to specific safe modules only
- The `consul-data/` directory (runtime state) is excluded from git

---

## 🤝 Contributing

Pull requests are welcome. For major changes please open an issue first to discuss what you would like to change.

1. Fork the repo
2. Create your feature branch (`git checkout -b feature/my-fix`)
3. Commit your changes (`git commit -m 'feat: add my fix'`)
4. Push to the branch (`git push origin feature/my-fix`)
5. Open a Pull Request

---

## 📄 License

[MIT](LICENSE)
