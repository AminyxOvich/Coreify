#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# OS Configuration — Monitoring Host
# Run ONCE before deploy-monitoring.sh on Fedora / RHEL-based systems
# Usage: sudo ./setup-os.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ─── Must run as root ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo ./setup-os.sh)"
  exit 1
fi

echo "=============================================="
echo "  Monitoring Host — OS Configuration"
echo "=============================================="

# ─── 1. Package prerequisites ────────────────────────────────────────────────
echo ""
echo "[1/7] Installing required packages..."
if command -v dnf &>/dev/null; then
  PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
  PKG_MGR="yum"
else
  echo "WARNING: Neither dnf nor yum found. Skipping package installation."
  PKG_MGR=""
fi

if [[ -n "$PKG_MGR" ]]; then
  $PKG_MGR install -y \
    docker-ce docker-ce-cli containerd.io docker-compose-plugin \
    policycoreutils-python-utils setools-console \
    curl wget jq net-tools bind-utils \
    2>/dev/null || {
      echo "  docker-ce not in repos — trying system docker..."
      $PKG_MGR install -y \
        docker docker-compose-plugin \
        policycoreutils-python-utils setools-console \
        curl wget jq net-tools bind-utils \
        2>/dev/null || echo "  Some packages may already be installed."
    }
fi

# ─── 2. Docker daemon configuration ─────────────────────────────────────────
echo ""
echo "[2/7] Configuring Docker daemon..."
mkdir -p /etc/docker

# Only write if not already customized
if [[ ! -f /etc/docker/daemon.json ]] || [[ $(cat /etc/docker/daemon.json 2>/dev/null) == "{}" ]]; then
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  },
  "metrics-addr": "127.0.0.1:9323",
  "experimental": true
}
EOF
  echo "  Created /etc/docker/daemon.json"
else
  echo "  /etc/docker/daemon.json already exists — skipping"
fi

systemctl enable docker
systemctl restart docker
echo "  Docker enabled and restarted."

# ─── 3. Firewall — open required ports ──────────────────────────────────────
echo ""
echo "[3/7] Configuring firewall rules..."
if command -v firewall-cmd &>/dev/null; then
  ZONE=$(firewall-cmd --get-default-zone)
  echo "  Default zone: $ZONE"

  # Define all ports the monitoring host needs open
  declare -A PORTS=(
    # Consul
    ["8500/tcp"]="Consul HTTP API + UI"
    ["8600/udp"]="Consul DNS"
    ["8300/tcp"]="Consul Server RPC"
    ["8301/tcp"]="Consul LAN Serf TCP"
    ["8301/udp"]="Consul LAN Serf UDP"
    ["8302/tcp"]="Consul WAN Serf TCP"
    ["8302/udp"]="Consul WAN Serf UDP"
    # Prometheus
    ["9090/tcp"]="Prometheus"
    # Grafana
    ["3000/tcp"]="Grafana"
    # Loki
    ["3100/tcp"]="Loki"
    # Node Exporter
    ["9100/tcp"]="Node Exporter"
    # Promtail
    ["9080/tcp"]="Promtail"
    # PostgreSQL
    ["5432/tcp"]="PostgreSQL"
  )

  for port in "${!PORTS[@]}"; do
    if ! firewall-cmd --zone="$ZONE" --query-port="$port" &>/dev/null; then
      firewall-cmd --zone="$ZONE" --add-port="$port" --permanent
      echo "  Opened $port (${PORTS[$port]})"
    else
      echo "  $port already open (${PORTS[$port]})"
    fi
  done

  # Allow Docker bridge subnet traffic
  DOCKER_SUBNET=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "172.17.0.0/16")
  if ! firewall-cmd --zone="$ZONE" --query-source="$DOCKER_SUBNET" &>/dev/null; then
    firewall-cmd --zone=trusted --add-source="$DOCKER_SUBNET" --permanent
    echo "  Trusted Docker bridge: $DOCKER_SUBNET"
  fi

  # Reload firewall
  firewall-cmd --reload
  echo "  Firewall reloaded."
else
  echo "  firewall-cmd not found — checking iptables..."
  if command -v iptables &>/dev/null; then
    # Accept established connections
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    # Consul
    iptables -A INPUT -p tcp --dport 8500 -j ACCEPT
    iptables -A INPUT -p udp --dport 8600 -j ACCEPT
    iptables -A INPUT -p tcp --dport 8300 -j ACCEPT
    iptables -A INPUT -p tcp --dport 8301 -j ACCEPT
    iptables -A INPUT -p udp --dport 8301 -j ACCEPT
    iptables -A INPUT -p tcp --dport 8302 -j ACCEPT
    iptables -A INPUT -p udp --dport 8302 -j ACCEPT
    # Services
    iptables -A INPUT -p tcp --dport 9090 -j ACCEPT  # Prometheus
    iptables -A INPUT -p tcp --dport 3000 -j ACCEPT  # Grafana
    iptables -A INPUT -p tcp --dport 3100 -j ACCEPT  # Loki
    iptables -A INPUT -p tcp --dport 9100 -j ACCEPT  # Node Exporter
    iptables -A INPUT -p tcp --dport 9080 -j ACCEPT  # Promtail
    iptables -A INPUT -p tcp --dport 5432 -j ACCEPT  # PostgreSQL
    echo "  iptables rules added."
  else
    echo "  WARNING: No firewall tool found. Ensure ports are open manually."
  fi
fi

# ─── 4. SELinux policies ────────────────────────────────────────────────────
echo ""
echo "[4/7] Configuring SELinux..."
if command -v getenforce &>/dev/null; then
  SELINUX_STATUS=$(getenforce)
  echo "  SELinux status: $SELINUX_STATUS"

  if [[ "$SELINUX_STATUS" != "Disabled" ]]; then
    # Allow containers to connect to any TCP port
    setsebool -P container_connect_any 1 2>/dev/null || true
    echo "  Set container_connect_any = on"

    # Allow container processes to access the Docker socket
    setsebool -P container_manage_cgroup 1 2>/dev/null || true
    echo "  Set container_manage_cgroup = on"

    # Allow Promtail to read host logs
    if command -v semanage &>/dev/null; then
      semanage fcontext -a -t container_file_t "/var/log(/.*)?" 2>/dev/null || true
      restorecon -Rv /var/log 2>/dev/null || true
      echo "  Set /var/log as container_file_t"

      # Allow containers to read docker socket
      semanage fcontext -a -t container_file_t "/var/run/docker.sock" 2>/dev/null || true
      restorecon -v /var/run/docker.sock 2>/dev/null || true
      echo "  Set docker.sock as container_file_t"
    fi

    # Install custom SELinux policy if the .te file exists
    if [[ -f monitoring_policy.te ]]; then
      echo "  Building custom SELinux policy module..."
      checkmodule -M -m -o /tmp/monitoring_policy.mod monitoring_policy.te 2>/dev/null && \
      semodule_package -o /tmp/monitoring_policy.pp -m /tmp/monitoring_policy.mod 2>/dev/null && \
      semodule -i /tmp/monitoring_policy.pp 2>/dev/null && \
      echo "  Installed monitoring_policy SELinux module" || \
      echo "  WARNING: Failed to build SELinux module — check monitoring_policy.te"
      rm -f /tmp/monitoring_policy.mod /tmp/monitoring_policy.pp
    fi
  fi
else
  echo "  SELinux not available on this system."
fi

# ─── 5. Sysctl kernel tuning ────────────────────────────────────────────────
echo ""
echo "[5/7] Applying sysctl kernel parameters..."
cat > /etc/sysctl.d/99-monitoring-stack.conf <<'EOF'
# ─── Monitoring Stack Tuning ─────────────────────────────────────────

# Network — increase connection tracking and buffer sizes
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# TCP keepalive — detect dead connections faster (important for Consul gossip)
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Allow more local ports for outbound connections (Prometheus scrapes many targets)
net.ipv4.ip_local_port_range = 10240 65535

# Connection tracking — increase for many concurrent connections
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 86400

# Enable IP forwarding (required for Docker bridge networking)
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

# File descriptors — Prometheus and Loki can open many files
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024

# Virtual memory — prevent OOM for Prometheus TSDB
vm.overcommit_memory = 1
vm.swappiness = 10
vm.max_map_count = 262144
EOF

sysctl --system > /dev/null 2>&1
echo "  Applied /etc/sysctl.d/99-monitoring-stack.conf"

# Load bridge module if needed for bridge-nf-call settings
modprobe br_netfilter 2>/dev/null || true
echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf 2>/dev/null || true

# ─── 6. User & group setup ──────────────────────────────────────────────────
echo ""
echo "[6/7] Setting up user permissions..."

# Add the current sudo user to docker group
SUDO_USER_NAME="${SUDO_USER:-}"
if [[ -n "$SUDO_USER_NAME" ]] && [[ "$SUDO_USER_NAME" != "root" ]]; then
  if ! groups "$SUDO_USER_NAME" | grep -q '\bdocker\b'; then
    usermod -aG docker "$SUDO_USER_NAME"
    echo "  Added $SUDO_USER_NAME to docker group (re-login required)"
  else
    echo "  $SUDO_USER_NAME already in docker group"
  fi
fi

# Create dedicated UIDs for containers that use user: directive
# Prometheus runs as nobody (65534), Loki needs loki user
if ! id -u loki &>/dev/null; then
  useradd -r -s /sbin/nologin -M loki 2>/dev/null || true
  echo "  Created system user: loki"
else
  echo "  User 'loki' already exists"
fi

# ─── 7. Directory and volume preparation ────────────────────────────────────
echo ""
echo "[7/7] Preparing directories..."

# Grafana provisioning
mkdir -p config/grafana/provisioning/datasources
echo "  Created grafana provisioning directory"

# Ensure /var/log is readable
chmod -R o+r /var/log/*.log 2>/dev/null || true

# Ensure docker socket is accessible
chmod 666 /var/run/docker.sock 2>/dev/null || true

echo ""
echo "=============================================="
echo "  OS configuration complete!"
echo "=============================================="
echo ""
echo "NEXT STEPS:"
echo "  1. If user was added to docker group → log out and back in"
echo "  2. Edit config/consul-server.hcl → set advertise_addr to your LAN IP"
echo "  3. Edit config/prometheus_file_sd.json → set target IPs"
echo "  4. cp .env.example .env && nano .env"
echo "  5. Run: ./deploy-monitoring.sh"
echo ""
