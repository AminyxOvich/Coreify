#!/bin/bash

# Function to check if user is in docker group
is_user_in_docker_group() {
  if groups "$USER" | grep -q '\bdocker\b'; then
    return 0 # User is in docker group
  else
    return 1 # User is not in docker group
  fi
}

# Add current user to docker group if not already a member
if ! is_user_in_docker_group; then
  echo "User '$USER' is not in the 'docker' group."
  echo "Attempting to add '$USER' to the 'docker' group. This requires sudo privileges."
  sudo usermod -aG docker "$USER"
  if [ $? -eq 0 ]; then
    echo "Successfully added '$USER' to the 'docker' group."
    echo "IMPORTANT: You need to log out and log back in for this change to take effect."
    echo "Please log out, log back in, and then re-run this script."
    exit 1
  else
    echo "Failed to add '$USER' to the 'docker' group. Please do this manually and then re-run the script."
    exit 1
  fi
fi

# Set execute permissions for necessary scripts
echo "Setting execute permissions for scripts..."
chmod +x ./consul/entrypoint.sh
chmod +x ./node-exporter/entrypoint.sh
chmod +x ./promtail/entrypoint.sh
chmod +x ./scripts/deploy.sh # Self-permissioning, good for consistency
chmod +x ./scripts/teardown.sh

# Load environment variables from .env file
if [ -f .env ]; then
  echo "Loading environment variables from .env file..."
  export $(grep -v '^#' .env | xargs)
else
  echo "Warning: .env file not found. Some configurations might be missing."
fi

# Bring down any existing services defined in docker-compose.yml
echo "Bringing down any existing services..."
docker-compose down

# Create necessary directories (idempotent)
echo "Ensuring necessary directories exist..."
mkdir -p ./consul/data
mkdir -p ./promtail # Changed from ./promtail/config as config.yml is a file mount

# docker-compose up depends on how they are used.
export CONSUL_CONFIG_PATH=./consul/consul.hcl
export NODE_EXPORTER_PORT=9100
export PROMTAIL_CONFIG_PATH=./promtail/config.yml

# Start the Docker Compose stack
echo "Starting the Docker Compose stack in detached mode..."
docker-compose up -d --build # Added --build to ensure images are up-to-date with any changes

# Display the status of the services
echo "Current status of services:"
docker-compose ps