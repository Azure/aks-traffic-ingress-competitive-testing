#!/bin/bash

# Script to install Vegeta HTTP load testing tool
# https://github.com/tsenart/vegeta

set -e

VEGETA_VERSION="12.12.0"
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
DOWNLOAD_URL="https://github.com/tsenart/vegeta/releases/download/v${VEGETA_VERSION}/vegeta_${VEGETA_VERSION}_linux_${ARCH}.tar.gz"

echo "Downloading Vegeta v${VEGETA_VERSION} for Linux ${ARCH}..."
wget -q "${DOWNLOAD_URL}" -O vegeta.tar.gz

echo "Extracting Vegeta..."
tar xzf vegeta.tar.gz vegeta

echo "Installing Vegeta to /usr/local/bin..."
sudo mv vegeta /usr/local/bin/
rm vegeta.tar.gz

echo "Setting executable permissions..."
sudo chmod +x /usr/local/bin/vegeta

echo "Verifying installation..."
vegeta --version

echo "Vegeta installation complete!"