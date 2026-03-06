#!/bin/bash

# Script to install ingress-nginx on a Kind cluster.
# This script expects to be run from the root directory of this project.

set -ex

echo "Installing ingress-nginx..."

# Apply the Kind-specific ingress-nginx manifest
kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml

# Wait for the ingress controller pods to be created
echo "Waiting for ingress-nginx pods to be created..."
sleep 10s

# Wait for the ingress-nginx controller to be ready
echo "Waiting for ingress-nginx controller to be ready..."
kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=90s

echo "ingress-nginx installed successfully"
