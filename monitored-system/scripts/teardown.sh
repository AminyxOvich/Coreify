#!/bin/bash

# Stop and remove the Docker containers
docker-compose down

# Remove any associated volumes
docker volume prune -f

# Optionally, remove any networks created by Docker Compose
docker network prune -f

echo "Teardown completed successfully."