# Monitored Node Stack

Deploy this stack on **each server you want to monitor**. It runs Consul agent, Node Exporter, and Promtail to ship metrics and logs to the central monitoring host.

---

## Architecture

```
┌─────────────────────────────────────────┐
│         Monitored Node (Host)           │
├─────────────────────────────────────────┤
│                                         │
│  ┌─────────────┐  ┌──────────────────┐ │
│  │   Consul    │  │  Node Exporter   │ │
│  │    Agent    │  │   (metrics)      │ │
│  │  port 8500  │  │   port 9100      │ │
│  └──────┬──────┘  └────────┬─────────┘ │
│         │                  │           │
│  ┌──────┴──────────────────┴─────────┐ │
│  │         Promtail (logs)           │ │
│  │          port 9080                │ │
│  └───────────────────────────────────┘ │
│         │                             │
└─────────┼─────────────────────────────┘
          │
          ▼ Sends to Monitoring Host
   (Consul Server, Prometheus, Loki)
```

**Network Mode:** All services use `network_mode: host` to enable Consul gossip protocol and simplify service discovery.

---

## Prerequisites

- **OS:** Fedora 38+, RHEL 9+, CentOS Stream 9+, or compatible Linux
- **Docker:** Version 20.10+ with Compose v2
- **Firewall:** Ports 8500, 8301, 9100, 9080 accessible from monitoring host
- **SELinux:** Must be configured to allow container access to `/var/run/docker.sock` and `/var/log`

---

## Deployment Steps

### 1. Configure the OS (Run Once)

```bash
sudo ./setup-os.sh
```

**What it does:**
- ✅ Installs Docker CE, SELinux tools, firewall utilities
- ✅ Configures Docker daemon with log rotation and ulimits
- ✅ Opens firewall ports: 8500 (Consul HTTP), 8301 UDP/TCP (Consul gossip), 9100 (Node Exporter), 9080 (Promtail push endpoint)
- ✅ Trusts the monitoring host IP in firewall trusted zone
- ✅ Compiles and installs SELinux policy (`promtail_docker_socket.te`) for container socket access
- ✅ Sets SELinux booleans: `container_connect_any=1`, `container_manage_cgroup=1`
- ✅ Tunes sysctl: TCP keepalive, conntrack limits, file descriptors, memory overcommit
- ✅ Tests connectivity to monitoring host (ping, port 8500, port 3100)
- ✅ Adds current user to `docker` group

**Reboot after first run** to apply kernel parameters and group membership.

---

### 2. Configure Environment Variables

```bash
cp .env.example .env
nano .env
```

**Required variables:**

| Variable | Example | Description |
|----------|---------|-------------|
| `MONITORING_HOST` | `192.168.1.100` | IP of the monitoring host (Consul server) |
| `CONSUL_NODE_NAME` | `monitored-node-01` | Unique name for this node (used in Consul, Prometheus labels) |
| `CONSUL_ADVERTISE` | `192.168.1.101` | This node's IP (for Consul cluster gossip) |

> **Naming Convention:** Use `monitored-node-01`, `monitored-node-02`, etc. The n8n self-healing workflow expects this pattern to match SaltStack minion IDs.

---

### 3. Deploy the Stack

```bash
./scripts/deploy.sh
```

**What it does:**
- Validates environment variables are set
- Checks that OS setup has been run
- Builds custom Consul agent image
- Starts 3 services:
  - **Consul Agent** (joins monitoring host cluster)
  - **Node Exporter** (exports hardware/OS metrics)
  - **Promtail** (ships system logs and Docker container logs to Loki)
- Waits for Consul to join the cluster
- Displays service status

---

## Services

### Consul Agent

- **Image:** Custom build from [Dockerfile](Dockerfile) (based on `hashicorp/consul:1.16`)
- **Purpose:** Register this node in the service mesh, enable Prometheus service discovery
- **Ports:** 8500 (HTTP API), 8301 UDP/TCP (LAN gossip), 8302 UDP/TCP (WAN gossip)
- **Healthcheck:** `consul members` (every 30s)
- **Config:** [consul/consul.hcl.template](consul/consul.hcl.template) (environment variables substituted at startup)

### Node Exporter

- **Image:** `prom/node-exporter:v1.8.2`
- **Purpose:** Expose hardware and OS metrics (CPU, memory, disk, network)
- **Ports:** 9100 (metrics endpoint)
- **Healthcheck:** `wget -qO- http://localhost:9100/metrics`
- **Resource Limits:** 256M memory, 0.25 CPU

### Promtail

- **Image:** `grafana/promtail:3.4.2`
- **Purpose:** Scrape logs from `/var/log` and Docker containers, push to Loki
- **Ports:** 9080 (HTTP server)
- **Config:** [promtail/config.yml](promtail/config.yml)
- **Volumes:**
  - `/var/log:/var/log:ro` (system logs)
  - `/var/run/docker.sock:/var/run/docker.sock:ro` (Docker container logs via API)
- **Healthcheck:** Waits for Consul agent to be healthy before starting
- **SELinux:** Requires custom policy to read `/var/run/docker.sock` and `/var/log`

---

## Configuration Files

### consul/consul.hcl.template

Template for Consul agent configuration. Environment variables are substituted at container startup:

- `${MONITORING_HOST}` → Consul server IP
- `${CONSUL_NODE_NAME}` → This node's unique name
- `${CONSUL_ADVERTISE}` → This node's IP for gossip

### promtail/config.yml

Log scraping configuration:

- **System logs:** Scrapes `/var/log/**/*.log` with `job=system_logs`, `host=${CONSUL_NODE_NAME}`
- **Docker logs:** Uses `docker_sd_configs` to discover all running containers, labels with container name and image

### docker-compose.yml

Main stack definition with:

- Host networking for all services
- Healthchecks on Consul and Promtail
- Resource limits (memory/CPU)
- Volume mounts for logs and Docker socket
- Dependency chain: Promtail waits for Consul to be healthy

---

## SELinux Policy

### promtail_docker_socket.te (v1.1)

Custom SELinux module allowing `container_t` processes to:

- Read Docker socket (`/var/run/docker.sock` → `docker_var_run_t`)
- Read system logs (`/var/log` → `var_log_t`)
- Bind to unprivileged ports (9080)

**Build and install:**

```bash
checkmodule -M -m -o promtail_docker_socket.mod promtail_docker_socket.te
semodule_package -o promtail_docker_socket.pp -m promtail_docker_socket.mod
sudo semodule -i promtail_docker_socket.pp
```

> **Note:** This is automatically done by `setup-os.sh`.

---

## Verification

### Check Consul Registration

```bash
# From the monitored node
curl http://localhost:8500/v1/agent/members | jq
```

You should see this node and the monitoring host in the member list.

### Check Metrics Scraping

```bash
# From the monitored node
curl http://localhost:9100/metrics | head -n 20
```

Should return Prometheus-formatted metrics.

### Check Log Shipping

```bash
# From the monitoring host
curl -G 'http://localhost:3100/loki/api/v1/query' \
  --data-urlencode "query={host=\"monitored-node-01\"}" | jq
```

Should return recent logs from this node.

---

## Troubleshooting

### Consul agent won't join cluster

1. **Check connectivity:**
   ```bash
   telnet $MONITORING_HOST 8500
   ```

2. **Check firewall:**
   ```bash
   sudo firewall-cmd --list-all
   ```
   Ensure ports 8500, 8301 are open.

3. **Check Consul logs:**
   ```bash
   docker logs consul-agent
   ```

### Promtail can't read Docker socket

1. **Check SELinux context:**
   ```bash
   ls -Z /var/run/docker.sock
   ```
   Should show `container_file_t` or `docker_var_run_t`.

2. **Check SELinux booleans:**
   ```bash
   getsebool container_connect_any
   ```
   Should be `on`.

3. **Reinstall SELinux policy:**
   ```bash
   sudo ./setup-os.sh
   ```

### High resource usage

Adjust resource limits in [docker-compose.yml](docker-compose.yml):

```yaml
deploy:
  resources:
    limits:
      memory: 128M   # Reduce from 256M
      cpus: "0.1"    # Reduce from 0.25
```

---

## Teardown

```bash
./scripts/teardown.sh
```

Stops and removes all containers. **Does not** uninstall SELinux policies or revert OS configuration.

---

## Files Reference

| File | Purpose |
|------|---------|
| [docker-compose.yml](docker-compose.yml) | Main stack definition |
| [Dockerfile](Dockerfile) | Custom Consul agent image |
| [.env.example](.env.example) | Environment variable template |
| [setup-os.sh](setup-os.sh) | One-time OS configuration script |
| [promtail_docker_socket.te](promtail_docker_socket.te) | SELinux policy for Promtail |
| [consul/consul.hcl.template](consul/consul.hcl.template) | Consul agent config template |
| [consul/entrypoint.sh](consul/entrypoint.sh) | Substitutes env vars in config |
| [promtail/config.yml](promtail/config.yml) | Log scraping configuration |
| [scripts/deploy.sh](scripts/deploy.sh) | Deployment script |
| [scripts/teardown.sh](scripts/teardown.sh) | Cleanup script |