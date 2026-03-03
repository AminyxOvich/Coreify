# Monitoring Stack — Fixes & Known Issues

This document tracks fixes applied during development and known configuration gotchas.

---

## ✅ Applied Fixes

### 1. Grafana / PostgreSQL — Hardcoded Credentials Removed
**Problem:** `docker-compose.monitoring.yml` had hardcoded `admin123` and `monitoring123` passwords.  
**Fix:** Replaced with environment variables (`GF_ADMIN_PASSWORD`, `POSTGRES_PASSWORD`) read from `.env`.  
**Action required:** Copy `monitoring-host-system/.env.example` → `.env` and set strong passwords before deploying.

---

### 2. Consul Server `advertise_addr` — Hardcoded IP Removed
**Problem:** `config/consul-server.hcl` had a hardcoded LAN IP `192.168.0.12`.  
**Fix:** Replaced with `YOUR_MONITORING_HOST_IP` placeholder.  
**Action required:** Edit `config/consul-server.hcl` and replace `YOUR_MONITORING_HOST_IP` with your actual monitoring host LAN IP.

---

### 3. Prometheus File SD — Hardcoded IPs Replaced
**Problem:** `config/prometheus_file_sd.json` contained real LAN IPs for all nodes.  
**Fix:** Replaced with `YOUR_MONITORING_HOST_IP`, `YOUR_NODE_01_IP`, `YOUR_NODE_02_IP` placeholders.  
**Action required:** Edit `prometheus_file_sd.json` with your actual node IPs before deploying.

---

### 4. n8n Workflow — Anomaly API Fallback
**Problem:** When the anomaly detection API (`:5000`) is unreachable, the workflow stalled.  
**Fix:** Added `Generate Fallback Anomaly Data` node that injects realistic Fedora firewalld/SELinux
log entries showing port 8000 blocked on `monitored-node-02`. This keeps the full pipeline testable
without a live anomaly API.

---

### 5. SaltStack `publisher_acl` — YAML Syntax
**Problem:** `/etc/salt/master` `publisher_acl` block may have incorrect indentation causing Salt
to silently ignore ACL rules.  
**Fix (manual):** Ensure the section looks like this (2-space indent throughout):

```yaml
publisher_acl:
  healing-agent:
    - '*':
      - cmd.run
      - firewalld.*
      - service.*
      - pkg.*
```

After editing, restart the Salt master: `sudo systemctl restart salt-master`

---

### 6. Promtail Docker Socket — SELinux Policy
**Problem:** On Fedora/RHEL with SELinux enforcing, Promtail cannot read `/var/run/docker.sock`.  
**Fix:** SELinux policy modules are provided in `monitored-system/`:
- `promtail_docker_socket.te` — Type enforcement source
- `promtail_docker_socket.pp` — Compiled policy (do not commit — in `.gitignore`)

To install:
```bash
cd monitored-system
sudo semodule -i promtail_docker_socket.pp
```

Or rebuild from source:
```bash
checkmodule -M -m -o promtail_docker_socket.mod promtail_docker_socket.te
semodule_package -o promtail_docker_socket.pp -m promtail_docker_socket.mod
sudo semodule -i promtail_docker_socket.pp
```

---

### 7. Docker Compose — Consul Data Volume Conflict
**Problem:** `monitored-system/docker-compose.yml` defines both a named volume `consul-data` and a
bind-mount `./consul-data`. This causes a conflict on first run.  
**Fix:** The `./consul-data/` bind-mount directory is excluded from git (`.gitignore`). Docker will
create it fresh on first deploy. Do not pre-create it manually.

---

## ⚠️ Known Remaining Issues

| Issue | Severity | Notes |
|-------|----------|-------|
| Promtail `:9080/ready` check may fail on cold start | Low | Add `depends_on: loki` or retry logic |
| Loki `boltdb-shipper` deprecated in Loki 3.x | Medium | Migrate to `tsdb` store if upgrading beyond 2.9 |
| `promtail-agent.yml` in `config/` is empty | Low | Placeholder for remote agent deployments |
| n8n workflow requires manual credential wiring after import | Medium | Credentials cannot be exported in workflow JSON |
| SaltStack minion must already be registered before healing executes | Medium | Pre-register minions with `salt-key -A` |
