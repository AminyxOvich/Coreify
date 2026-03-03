FROM hashicorp/consul:1.16

# Try to install gettext-tiny which may be available in Alpine
RUN apk update && \
    (apk add --no-cache gettext || \
     apk add --no-cache gettext-tiny || \
     echo "Warning: Could not install gettext, will use sed for substitution")

# Copy only the Consul entrypoint script
COPY consul/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]