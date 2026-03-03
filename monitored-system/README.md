# Monitored System Configuration

This project sets up a monitored system using Docker Compose, integrating services for Consul Agent, Node Exporter, and Promtail. Below are the details for each component and instructions for deployment.

## Project Structure

```
monitored-system-config
├── docker-compose.yml
├── consul
│   ├── consul.hcl
│   └── entrypoint.sh
├── node-exporter
│   └── entrypoint.sh
├── promtail
│   ├── config.yml
│   └── entrypoint.sh
├── scripts
│   ├── deploy.sh
│   └── teardown.sh
└── README.md
```

## Services

### Consul Agent
- **Configuration**: Located in `consul/consul.hcl`, this file defines the parameters for the Consul Agent, including datacenter, data directory, logging level, service registration, health checks, and telemetry settings.
- **Entrypoint**: The `entrypoint.sh` script in the `consul` directory starts the Consul Agent with the specified configuration.

### Node Exporter
- **Entrypoint**: The `entrypoint.sh` script in the `node-exporter` directory starts the Node Exporter to collect system metrics.

### Promtail
- **Configuration**: The `config.yml` file in the `promtail` directory specifies server settings, client URLs, and scrape configurations for collecting logs from the system and Docker containers.
- **Entrypoint**: The `entrypoint.sh` script in the `promtail` directory starts Promtail with the specified configuration.

## Deployment

To deploy the monitored system, run the following command in the project root directory:

```bash
./scripts/deploy.sh
```

This script will create necessary directories, set environment variables, and start the Docker Compose stack.

## Teardown

To stop and remove the Docker containers and clean up resources, run:

```bash
./scripts/teardown.sh
```

## Requirements

- Docker
- Docker Compose

## Usage

After deployment, you can access the services as defined in the `docker-compose.yml` file. Ensure to check the logs for each service to monitor their status and performance.

## Contributing

Feel free to contribute to this project by submitting issues or pull requests. Your feedback and improvements are welcome!