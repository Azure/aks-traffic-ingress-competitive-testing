#!/bin/bash

# Script to install Vegeta HTTP load testing tool and jaggr
# https://github.com/tsenart/vegeta
# https://github.com/rs/jaggr

set -e

# Install Vegeta
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

# Download URL for Vegeta
DOWNLOAD_URL="https://github.com/tsenart/vegeta/releases/download/v${VEGETA_VERSION}/vegeta_${VEGETA_VERSION}_linux_${ARCH}.tar.gz"

echo "Downloading Vegeta v${VEGETA_VERSION} for Linux ${ARCH}..."
wget -q "${DOWNLOAD_URL}" -O vegeta.tar.gz

echo "Extracting Vegeta..."
tar xzf vegeta.tar.gz vegeta

echo "Installing Vegeta to /usr/local/bin..."
sudo mv vegeta /usr/local/bin/
rm vegeta.tar.gz

echo "Setting executable permissions for Vegeta..."
sudo chmod +x /usr/local/bin/vegeta

echo "Verifying Vegeta installation..."
vegeta --version

# Install jaggr
JAGGR_VERSION="1.0.0"
JAGGR_URL="https://github.com/rs/jaggr/releases/download/${JAGGR_VERSION}/jaggr_${JAGGR_VERSION}_linux_${ARCH}.tar.gz"

echo "Downloading jaggr v${JAGGR_VERSION} for Linux ${ARCH}..."
wget -q "${JAGGR_URL}" -O jaggr.tar.gz

echo "Extracting jaggr..."
tar xzf jaggr.tar.gz jaggr

echo "Installing jaggr to /usr/local/bin..."
sudo mv jaggr /usr/local/bin/
rm jaggr.tar.gz

echo "Setting executable permissions for jaggr..."
sudo chmod +x /usr/local/bin/jaggr

echo "Installation complete!"
echo "Installed tools:"
echo "- Vegeta: $(vegeta --version)"
echo "- jaggr: "
jaggr --version