# Multi-stage Dockerfile for AKS Traffic Ingress Competitive Testing

# Base stage with common dependencies
FROM ubuntu:22.04 AS base

# Avoid interactive prompts during apt-get
ENV DEBIAN_FRONTEND=noninteractive

# Install common dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    jq \
    unzip \
    bash \
    ca-certificates \
    gnupg \
    apt-transport-https \
    lsb-release \
    iproute2 \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Create a fake sudoo command that redirects to sudo (to handle typos in scripts)
RUN echo '#!/bin/bash\nsudo "$@"' > /usr/local/bin/sudoo && \
    chmod +x /usr/local/bin/sudoo

# Install Go (required for KIND, jplot, and other Go tools)
ENV GOLANG_VERSION=1.23.0
ENV PATH=$PATH:/usr/local/go/bin:/root/go/bin
RUN curl -L https://go.dev/dl/go${GOLANG_VERSION}.linux-amd64.tar.gz | tar -C /usr/local -xzf - && \
    mkdir -p /root/go/bin

# Install Docker CLI for KIND
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

# Install kubectl
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/

# Install Helm
RUN curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && \
    chmod 700 get_helm.sh && \
    ./get_helm.sh && \
    rm get_helm.sh

# Tools installation stage
FROM base AS tools

WORKDIR /app

# Copy the repository
COPY . .

# Make all scripts executable
RUN chmod +x modules/**/install/*.sh modules/**/run/*.sh modules/**/test/*.sh scenarios/*.sh

# Create sudoers file for the root user to avoid sudo errors
RUN echo "root ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/root && \
    chmod 0440 /etc/sudoers.d/root

# Install Vegeta
RUN bash modules/vegeta/install/install.sh


# Server build stage
FROM tools AS server-builder

WORKDIR /app/server

# Build the server
RUN CGO_ENABLED=0 GOOS=linux go build -o server

# Final stage
FROM tools AS final

WORKDIR /app

# Copy server binary from builder
COPY --from=server-builder /app/server/server /app/server/

# Create entrypoint script to handle different commands
RUN printf '%s\n' \
    '#!/bin/bash' \
    'if [ $# -eq 0 ]; then' \
    '  echo "AKS Traffic Ingress Competitive Testing Environment"' \
    '  echo "Available commands:"' \
    '  echo "- Run scenario: docker run <image> basic-rps [args...]"' \
    '  echo "- Run server: docker run <image> server"' \
    '  echo "- Run custom command: docker run <image> bash -c \"your_command\""' \
    'elif [ "$1" = "server" ]; then' \
    '  cd /app/server && ./server' \
    'elif [ -f "/app/scenarios/$1/run/run.sh" ]; then' \
    '  scenario_name="$1"' \
    '  shift' \
    '  bash "/app/scenarios/${scenario_name}/run/run.sh" "$@"' \
    'else' \
    '  exec "$@"' \
    'fi' \
    > /app/entrypoint.sh && chmod +x /app/entrypoint.sh

SHELL [ "/bin/bash", "-c" ]

# Set entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]

# Default command - if no arguments provided, this will show usage information
CMD []

# Usage examples in comments:
# Run basic RPS scenario:
# docker run ghcr.io/azure/aks-traffic-ingress-competitive-testing basic-rps
#
# Run the server:
# docker run -p 3333:3333 ghcr.io/azure/aks-traffic-ingress-competitive-testing server
