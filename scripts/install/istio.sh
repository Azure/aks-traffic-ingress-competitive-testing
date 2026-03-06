#!/bin/bash

# Script to install Istio with Gateway API support on a Kind cluster.
# This script expects to be run from the root directory of this project.

set -ex

# ---------------------------------------------------------------------------
# Install Gateway API CRDs
# ---------------------------------------------------------------------------

echo "Applying Gateway API CRDs..."
kubectl apply -f ./manifests/crds/gateway-crd.yaml

# ---------------------------------------------------------------------------
# Install Istio
# ---------------------------------------------------------------------------

echo "Installing istioctl..."
curl -L https://istio.io/downloadIstio | sh -

# Derive the directory name from the istioctl binary that was just downloaded
ISTIO_DIR=$(find . -maxdepth 1 -type d -name 'istio-*' -printf '%T@ %p\n' | sort -rn | head -n1 | cut -d' ' -f2)
export PATH="${ISTIO_DIR}/bin:${PATH}"

echo "Verifying istioctl installation..."
istioctl version --remote=false

echo "Installing Istio with minimal profile..."
istioctl install --set profile=minimal -y

# Wait for istiod to be ready
echo "Waiting for istiod to be ready..."
kubectl wait --namespace istio-system \
    --for=condition=ready pod \
    --selector=app=istiod \
    --timeout=120s

echo "Istio installed successfully"
