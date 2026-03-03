# Monitoring Host System

This project sets up a comprehensive monitoring host system using various tools and services, including Consul, Prometheus, Grafana, Loki, Vector, Node Exporter, and Promtail. The following sections provide an overview of the components and instructions for setting up the system.

## Project Structure

The project consists of the following files and directories:

- **docker-compose.monitoring.yml**: Defines the services for the monitoring host system using Docker Compose.
- **config/**: Contains configuration files for each service:
  - **consul-server.hcl**: Configuration for the Consul server.
  - **prometheus.yml**: Configuration for Prometheus.
  - **consul-rules.yml**: Alerting and recording rules for Prometheus.
  - **loki.yml**: Configuration for Loki.
  - **vector.toml**: Configuration for Vector.
  - **promtail.yml**: Configuration for Promtail.
  - **grafana/provisioning/**: Directory for Grafana provisioning configurations.

## Getting Started

To set up the monitoring host system, follow these steps:

1. **Clone the Repository**: Clone this repository to your local machine.
   
   ```bash
   git clone <repository-url>
   cd monitoring-host-system
   ```

2. **Start the Services**: Use Docker Compose to start all the services defined in the `docker-compose.monitoring.yml` file.

   ```bash
   docker-compose -f docker-compose.monitoring.yml up -d
   ```

3. **Access the Services**:
   - **Consul**: [http://localhost:8500](http://localhost:8500)
   - **Prometheus**: [http://localhost:9090](http://localhost:9090)
   - **Grafana**: [http://localhost:3000](http://localhost:3000) (default credentials: admin/admin123)
   - **Loki**: [http://localhost:3100](http://localhost:3100)
   - **Vector**: [http://localhost:8686](http://localhost:8686)
   - **Node Exporter**: [http://localhost:9100](http://localhost:9100)
   - **Promtail**: [http://localhost:9080](http://localhost:9080)

## Configuration

Each service can be configured by modifying the respective configuration files located in the `config/` directory. Ensure that the configurations meet your monitoring requirements.

## Contributing

Contributions are welcome! Please submit a pull request or open an issue for any enhancements or bug fixes.

## License

This project is licensed under the MIT License. See the LICENSE file for more details.