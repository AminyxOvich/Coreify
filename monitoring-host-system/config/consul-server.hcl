datacenter = "monitoring-dc"
data_dir = "/consul/data"
log_level = "INFO"
node_name = "consul-monitoring-server"
bind_addr = "0.0.0.0"
client_addr = "0.0.0.0"
advertise_addr = "YOUR_MONITORING_HOST_IP"   # Replace with your monitoring host IP

server = true
bootstrap_expect = 1
ui_config {
  enabled = true
}

connect {
  enabled = true
}

ports {
  grpc = 8502
  http = 8500
  https = -1
  dns = 8600
}

# ─── Service Registrations ───────────────────────────────────────────

services {
  name = "consul"
  id = "consul-server"
  port = 8500
  tags = ["consul", "service-discovery", "monitoring-stack"]

  check {
    http = "http://localhost:8500/v1/status/leader"
    interval = "10s"
    timeout = "3s"
  }

  meta = {
    version = "1.16"
    role = "server"
    environment = "monitoring"
  }
}

services {
  name = "prometheus"
  id = "prometheus-monitoring"
  address = "prometheus"
  port = 9090
  tags = ["prometheus", "metrics", "monitoring-stack"]

  check {
    http = "http://prometheus:9090/-/healthy"
    interval = "15s"
    timeout = "5s"
  }

  meta = {
    version = "2.53.4"
    scrape_interval = "15s"
  }
}

services {
  name = "grafana"
  id = "grafana-monitoring"
  address = "grafana"
  port = 3000
  tags = ["grafana", "visualization", "monitoring-stack"]

  check {
    http = "http://grafana:3000/api/health"
    interval = "30s"
    timeout = "5s"
  }

  meta = {
    version = "11.5.2"
  }
}

services {
  name = "loki"
  id = "loki-monitoring"
  address = "loki"
  port = 3100
  tags = ["loki", "logs", "monitoring-stack"]

  check {
    http = "http://loki:3100/ready"
    interval = "30s"
    timeout = "5s"
  }

  meta = {
    version = "3.4.2"
  }
}

services {
  name = "node-exporter"
  id = "node-exporter-monitoring-host"
  address = "node-exporter"
  port = 9100
  tags = ["node-exporter", "metrics", "monitoring-host"]

  check {
    http = "http://node-exporter:9100/metrics"
    interval = "30s"
    timeout = "5s"
  }

  meta = {
    version = "1.8.2"
    node_type = "monitoring-host"
  }
}

services {
  name = "promtail"
  id = "promtail-monitoring-host"
  address = "promtail"
  port = 9080
  tags = ["promtail", "logs", "monitoring-host"]

  check {
    http = "http://promtail:9080/ready"
    interval = "30s"
    timeout = "5s"
  }

  meta = {
    version = "3.4.2"
    node_type = "monitoring-host"
  }
}

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname = true
}
