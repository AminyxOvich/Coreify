#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# OS Configuration — Monitored Node
# Run ONCE before scripts/deploy.sh on Fedora / RHEL-based systems
# Usage: sudo ./setup-os.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ─── Must run as root ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo ./setup-os.sh)"
  exit 1
fi

echo "=============================================="
echo "  Monitored Node — OS Configuration"
echo "=============================================="

# ─── Load .env for reference ──────────────────────────────────────────────────
if [[ -f .env ]]; then
  set -a; source .env; set +a
  echo "  Loaded .env"
elif [[ -f .env.example ]]; then
  echo "  WARNING: .env not found. Copy .env.example to .env first for full setup."
  echo "  Continuing with defaults for now..."
fi

MONITORING_HOST="${MONITORING_HOST:-<MONITORING_HOST_IP>}"
CONSUL_ADVERTISE="${CONSUL_ADVERTISE:-<THIS_NODE_IP>}"

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
    curl wget jq net-tools \
    2>/dev/null || {
      echo "  docker-ce not in repos — trying system docker..."
      $PKG_MGR install -y \
        docker docker-compose-plugin \
        policycoreutils-python-utils setools-console \
        curl wget jq net-tools \
        2>/dev/null || echo "  Some packages may already be installed."
    }
fi

# ─── 2. Docker daemon configuration ─────────────────────────────────────────
echo ""
echo "[2/7] Configuring Docker daemon..."
mkdir -p /etc/docker

if [[ ! -f /etc/docker/daemon.json ]] || [[ $(cat /etc/docker/daemon.json 2>/dev/null) == "{}" ]]; then
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  }
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

  # Ports this node exposes + ports for Consul agent gossip
  declare -A PORTS=(
    # Consul Agent
    ["8500/tcp"]="Consul Agent HTTP"
    ["8301/tcp"]="Consul LAN Serf TCP"
    ["8301/udp"]="Consul LAN Serf UDP"
    # Node Exporter
    ["9100/tcp"]="Node Exporter"
    # Promtail
    ["9080/tcp"]="Promtail"
  )

  for port in "${!PORTS[@]}"; do
    if ! firewall-cmd --zone="$ZONE" --query-port="$port" &>/dev/null; then
      firewall-cmd --zone="$ZONE" --add-port="$port" --permanent
      echo "  Opened $port (${PORTS[$port]})"
    else
      echo "  $port already open (${PORTS[$port]})"
    fi
  done

  # Allow traffic TO the monitoring host (Loki push, Consul server)
  # This ensures outbound to: 3100 (Loki), 8500/8300/8301 (Consul server)
  # Typically outbound is allowed, but some strict setups block it
  echo "  Verifying outbound connectivity to monitoring host..."

  # Trust Docker bridge traffic (for host network mode containers)
  DOCKER_SUBNET=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "172.17.0.0/16")
  if ! firewall-cmd --zone=trusted --query-source="$DOCKER_SUBNET" &>/dev/null; then
    firewall-cmd --zone=trusted --add-source="$DOCKER_SUBNET" --permanent
    echo "  Trusted Docker bridge: $DOCKER_SUBNET"
  fi

  # If MONITORING_HOST is set, allow all traffic to/from it
  if [[ "$MONITORING_HOST" != "<MONITORING_HOST_IP>" ]]; then
    if ! firewall-cmd --zone=trusted --query-source="${MONITORING_HOST}/32" &>/dev/null; then
      firewall-cmd --zone=trusted --add-source="${MONITORING_HOST}/32" --permanent
      echo "  Trusted monitoring host: $MONITORING_HOST"
    fi
  fi

  firewall-cmd --reload
  echo "  Firewall reloaded."
else
  echo "  firewall-cmd not found — checking iptables..."
  if command -v iptables &>/dev/null; then
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport 8500 -j ACCEPT  # Consul Agent
    iptables -A INPUT -p tcp --dport 8301 -j ACCEPT  # Consul Serf
    iptables -A INPUT -p udp --dport 8301 -j ACCEPT  # Consul Serf
    iptables -A INPUT -p tcp --dport 9100 -j ACCEPT  # Node Exporter
    iptables -A INPUT -p tcp --dport 9080 -j ACCEPT  # Promtail
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
    # Allow Consul agent container to bind to host ports
    setsebool -P container_connect_any 1 2>/dev/null || true
    echo "  Set container_connect_any = on"

    # Allow containers to manage cgroups (needed for host network mode)
    setsebool -P container_manage_cgroup 1 2>/dev/null || true
    echo "  Set container_manage_cgroup = on"

    # Promtail needs to read host logs and Docker socket
    if command -v semanage &>/dev/null; then
      # Host logs
      semanage fcontext -a -t container_file_t "/var/log(/.*)?" 2>/dev/null || true
      restorecon -Rv /var/log 2>/dev/null || true
      echo "  Set /var/log as container_file_t"

      # Docker socket — Promtail reads container logs via SD
      semanage fcontext -a -t container_file_t "/var/run/docker.sock" 2>/dev/null || true
      restorecon -v /var/run/docker.sock 2>/dev/null || true
      echo "  Set docker.sock as container_file_t"

      # /proc, /sys for node-exporter (usually already allowed)
      setsebool -P container_use_cephfs 0 2>/dev/null || true
    fi

    # Install the Promtail Docker socket policy module if .te exists
    if [[ -f promtail_docker_socket.te ]]; then
      echo "  Building promtail_docker_socket SELinux module..."
      checkmodule -M -m -o /tmp/promtail_docker_socket.mod promtail_docker_socket.te 2>/dev/null && \
      semodule_package -o /tmp/promtail_docker_socket.pp -m /tmp/promtail_docker_socket.mod 2>/dev/null && \
      semodule -i /tmp/promtail_docker_socket.pp 2>/dev/null && \
      echo "  Installed promtail_docker_socket SELinux module" || \
      echo "  WARNING: Failed to build SELinux module — check promtail_docker_socket.te"
      rm -f /tmp/promtail_docker_socket.mod /tmp/promtail_docker_socket.pp
    fi
  fi
else
  echo "  SELinux not available on this system."
fi

# ─── 5. Sysctl kernel tuning ────────────────────────────────────────────────
echo ""
echo "[5/7] Applying sysctl kernel parameters..."
cat > /etc/sysctl.d/99-monitored-node.conf <<'EOF'
# ─── Monitored Node Tuning ──────────────────────────────────────────

# Network — reasonable buffer sizes for metric/log shipping
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608

# TCP keepalive — detect dead connections faster (Consul gossip, Loki push)
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Allow sufficient local ports for Promtail/Consul outbound
net.ipv4.ip_local_port_range = 10240 65535

# IP forwarding — required for Docker (even with host network mode)
net.ipv4.ip_forward = 1

# File descriptors
fs.file-max = 1048576
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# Virtual memory
vm.swappiness = 10
EOF

sysctl --system > /dev/null 2>&1
echo "  Applied /etc/sysctl.d/99-monitored-node.conf"

# Load bridge module
modprobe br_netfilter 2>/dev/null || true
echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf 2>/dev/null || true

# ─── 6. User & group setup ──────────────────────────────────────────────────
echo ""
echo "[6/7] Setting up user permissions..."

SUDO_USER_NAME="${SUDO_USER:-}"
if [[ -n "$SUDO_USER_NAME" ]] && [[ "$SUDO_USER_NAME" != "root" ]]; then
  if ! groups "$SUDO_USER_NAME" | grep -q '\bdocker\b'; then
    usermod -aG docker "$SUDO_USER_NAME"
    echo "  Added $SUDO_USER_NAME to docker group (re-login required)"
  else
    echo "  $SUDO_USER_NAME already in docker group"
  fi
fi

# ─── 7. Connectivity pre-check ──────────────────────────────────────────────
echo ""
echo "[7/7] Checking connectivity to monitoring host..."

if [[ "$MONITORING_HOST" != "<MONITORING_HOST_IP>" ]]; then
  echo "  Monitoring host: $MONITORING_HOST"

  # Ping check
  if ping -c 1 -W 3 "$MONITORING_HOST" &>/dev/null; then
    echo "  ✓ Ping OK"
  else
    echo "  ✗ Ping FAILED — check network/firewall between nodes"
  fi

  # Consul port check
  if timeout 3 bash -c "echo > /dev/tcp/$MONITORING_HOST/8500" 2>/dev/null; then
    echo "  ✓ Consul (8500) reachable"
  else
    echo "  ✗ Consul (8500) NOT reachable — deploy monitoring host first"
  fi

  # Loki port check
  if timeout 3 bash -c "echo > /dev/tcp/$MONITORING_HOST/3100" 2>/dev/null; then
    echo "  ✓ Loki (3100) reachable"
  else
    echo "  ✗ Loki (3100) NOT reachable — Promtail won't be able to push logs"
  fi
else
  echo "  MONITORING_HOST not set — skipping connectivity check"
  echo "  Set it in .env, then re-run this check with:"
  echo "    curl -s http://<MONITORING_HOST>:8500/v1/status/leader"
fi

echo ""
echo "=============================================="
echo "  OS configuration complete!"
echo "=============================================="
echo ""
echo "NEXT STEPS:"
if [[ "$MONITORING_HOST" == "<MONITORING_HOST_IP>" ]]; then
  echo "  1. cp .env.example .env && nano .env  (set MONITORING_HOST, CONSUL_NODE_NAME, CONSUL_ADVERTISE)"
else
  echo "  1. Verify .env settings are correct"
fi
echo "  2. If user was added to docker group → log out and back in"
echo "  3. Run: ./scripts/deploy.sh"
echo ""
