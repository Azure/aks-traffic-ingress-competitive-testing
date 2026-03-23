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
RUN find modules -name "*.sh" -exec chmod +x {} + && \
    find scripts -name "*.sh" -exec chmod +x {} +

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
    '  echo ""' \
    '  echo "Usage: docker run <image> <command> [args...]"' \
    '  echo ""' \
    '  echo "Commands:"' \
    '  echo "  master [args...]                          Run the full test pipeline (scripts/master.sh)"' \
    '  echo "  scenario/<name> [args...]                  Run a scenario (e.g. scenario/basic_rps)"' \
    '  echo "  install/<name> [args...]                   Run an install script (e.g. install/nginx)"' \
    '  echo "  setup/<name> [args...]                     Run a setup script (e.g. setup/ingress)"' \
    '  echo "  module/<name>/<action> [args...]           Run a module script (e.g. module/vegeta/run)"' \
    '  echo "  server                                     Start the HTTP server"' \
    '  echo "  bash -c \"...\"                              Run a custom command"' \
    '  echo ""' \
    '  echo "Examples:"' \
    '  echo "  docker run <image> master --traffic ingress --scenario basic-rps"' \
    '  echo "  docker run <image> scenario/basic_rps --ingress-url http://localhost:8080 --rate 50"' \
    '  echo "  docker run <image> install/nginx"' \
    '  echo "  docker run <image> setup/ingress --ingress-class nginx --replica-count 3"' \
    '  echo "  docker run <image> module/vegeta/install"' \
    '  echo "  docker run <image> module/vegeta/run --target-url http://localhost:8080 --rate 50 --duration 30s"' \
    '  echo "  docker run <image> module/kind/output host_port"' \
    '  echo "  docker run -p 3333:3333 <image> server"' \
    'elif [ "$1" = "server" ]; then' \
    '  cd /app/server && ./server' \
    'elif [ "$1" = "master" ]; then' \
    '  shift' \
    '  exec bash /app/scripts/master.sh "$@"' \
    'elif [[ "$1" == scenario/* ]]; then' \
    '  name="${1#scenario/}"' \
    '  shift' \
    '  if [ -f "/app/scripts/scenarios/${name}.sh" ]; then' \
    '    exec bash "/app/scripts/scenarios/${name}.sh" "$@"' \
    '  else' \
    '    echo "ERROR: Unknown scenario: ${name}"' \
    '    echo "Available scenarios:"' \
    '    ls /app/scripts/scenarios/*.sh 2>/dev/null | sed "s|/app/scripts/scenarios/||;s|\.sh||" | sed "s|^|  |"' \
    '    exit 1' \
    '  fi' \
    'elif [[ "$1" == install/* ]]; then' \
    '  name="${1#install/}"' \
    '  shift' \
    '  if [ -f "/app/scripts/install/${name}.sh" ]; then' \
    '    exec bash "/app/scripts/install/${name}.sh" "$@"' \
    '  else' \
    '    echo "ERROR: Unknown install script: ${name}"' \
    '    echo "Available install scripts:"' \
    '    ls /app/scripts/install/*.sh 2>/dev/null | sed "s|/app/scripts/install/||;s|\.sh||" | sed "s|^|  |"' \
    '    exit 1' \
    '  fi' \
    'elif [[ "$1" == setup/* ]]; then' \
    '  name="${1#setup/}"' \
    '  shift' \
    '  if [ -f "/app/scripts/setup/${name}.sh" ]; then' \
    '    exec bash "/app/scripts/setup/${name}.sh" "$@"' \
    '  else' \
    '    echo "ERROR: Unknown setup script: ${name}"' \
    '    echo "Available setup scripts:"' \
    '    ls /app/scripts/setup/*.sh 2>/dev/null | sed "s|/app/scripts/setup/||;s|\.sh||" | sed "s|^|  |"' \
    '    exit 1' \
    '  fi' \
    'elif [[ "$1" == module/* ]]; then' \
    '  path="${1#module/}"' \
    '  module_name="${path%%/*}"' \
    '  action="${path#*/}"' \
    '  shift' \
    '  script="/app/modules/${module_name}/${action}/${action}.sh"' \
    '  if [ -f "$script" ]; then' \
    '    exec bash "$script" "$@"' \
    '  else' \
    '    echo "ERROR: Unknown module script: module/${module_name}/${action}"' \
    '    echo "Available modules and actions:"' \
    '    for m in /app/modules/*/; do' \
    '      mname=$(basename "$m")' \
    '      actions=$(ls "$m"/*//*.sh 2>/dev/null | xargs -I{} basename $(dirname {}) | sort -u | tr "\\n" " ")' \
    '      [ -n "$actions" ] && echo "  module/${mname}/{${actions}}"' \
    '    done' \
    '    exit 1' \
    '  fi' \
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
# Run full pipeline:
# docker run ghcr.io/azure/aks-traffic-ingress-competitive-testing master --traffic ingress --scenario basic-rps
#
# Run a scenario:
# docker run ghcr.io/azure/aks-traffic-ingress-competitive-testing scenario/basic_rps --ingress-url http://localhost:8080 --rate 50
#
# Run an install script:
# docker run ghcr.io/azure/aks-traffic-ingress-competitive-testing install/nginx
#
# Run a setup script:
# docker run ghcr.io/azure/aks-traffic-ingress-competitive-testing setup/ingress --ingress-class nginx
#
# Run a module script:
# docker run ghcr.io/azure/aks-traffic-ingress-competitive-testing module/vegeta/install
# docker run ghcr.io/azure/aks-traffic-ingress-competitive-testing module/vegeta/run --target-url http://localhost:8080 --rate 50 --duration 30s
# docker run ghcr.io/azure/aks-traffic-ingress-competitive-testing module/kind/output host_port
#
# Run the server:
# docker run -p 3333:3333 ghcr.io/azure/aks-traffic-ingress-competitive-testing server
