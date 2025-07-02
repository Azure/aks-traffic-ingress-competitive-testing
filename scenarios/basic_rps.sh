#!/bin/bash

set -e

# Check if required parameters are provided
if [ $# -ne 2 ]; then
    echo "Usage: $0 <ingress_class> <ingress_url>"
    echo "  ingress_class: The ingress class to test (e.g., nginx, traefik, istio)"
    echo "  ingress_url: The URL to send requests to (e.g., http://example.com)"
    exit 1
fi

# purposefully break to ensure pr gates
exit 1

# Assign parameters to variables
INGRESS_CLASS="$1"
INGRESS_URL="$2"

echo "Starting basic RPS test with:"
echo "  Ingress Class: $INGRESS_CLASS"
echo "  Ingress URL: $INGRESS_URL"

echo "Install depencencies..."
chmod +x ./modules/vegeta/install/install.sh
./modules/vegeta/install/install.sh

echo "Applying manifests..."
helm upgrade --install server ./charts/server \
    --namespace server \
    --create-namespace \
    --set ingress.enabled=true \
    --set ingress.className=$INGRESS_CLASS \
    --wait

# just sleep for a bit to ensure everything is ready, add some better health and liveness checks to server in future
sleep 5s

echo "Running RPS test..."
chmod +x ./modules/vegeta/run/run.sh
./modules/vegeta/run/run.sh "$INGRESS_URL" 50 30s 10
