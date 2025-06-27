#!/bin/bash

# Script to install KIND (Kubernetes IN Docker)
# https://kind.sigs.k8s.io/

set -e

# Get latest KIND version
LATEST_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | grep -Po '"tag_name": "v\K[^"]*')
ARCH=$(uname -m)

# Map architecture names
case ${ARCH} in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64)
        ARCH="arm64"
        ;;
    *)
        echo "Unsupported architecture: ${ARCH}"
        exit 1
        ;;
esac

# Download URL
DOWNLOAD_URL="https://kind.sigs.k8s.io/dl/v${LATEST_VERSION}/kind-linux-${ARCH}"

echo "Downloading KIND v${LATEST_VERSION} for Linux ${ARCH}..."
curl -Lo ./kind "${DOWNLOAD_URL}"

echo "Installing KIND to /usr/local/bin..."
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

echo "Verifying installation..."
kind version

echo "KIND installation complete!"

# Verify Docker is installed
if ! command -v docker &> /dev/null; then
    echo "WARNING: Docker is required for KIND but is not installed."
    echo "Please install Docker before using KIND."
    exit 1
fi