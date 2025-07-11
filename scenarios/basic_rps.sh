#!/bin/bash

set -e

# Check if required parameters are provided
if [ $# -ne 6 ]; then
    echo "Usage: $0 <ingress_class> <ingress_url> <rate> <duration> <workers>"
    echo "  ingress_class: The ingress class to test (e.g., nginx, traefik, istio)"
    echo "  ingress_url: The URL to send requests to (e.g., http://example.com)"
    echo "  rate: The rate of requests per second (e.g., 50)"
    echo "  duration: The duration of the test (e.g., 30s)"
    echo "  workers: The number of worker processes to use (e.g., 10)"
    echo "  replica_count: The number of replicas for the server deployment (e.g., 3)"
    exit 1
fi

# Assign parameters to variables
INGRESS_CLASS="$1"
INGRESS_URL="$2"
RATE="$3"
DURATION="$4"
WORKERS="$5"
REPLICA_COUNT="$6"

echo "Starting basic RPS test with:"
echo "  Ingress Class: $INGRESS_CLASS"
echo "  Ingress URL: $INGRESS_URL"
echo "  Rate: $RATE"
echo "  Duration: $DURATION"
echo "  Workers: $WORKERS"
echo "  Replica Count: $REPLICA_COUNT"

echo "Install dependencies..."
chmod +x ./modules/vegeta/install/install.sh
./modules/vegeta/install/install.sh

echo "Applying manifests..."
helm upgrade --install server ./charts/server \
    --namespace server \
    --create-namespace \
    --set ingress.enabled=true \
    --set ingress.className=$INGRESS_CLASS \
    --set replicaCount=$REPLICA_COUNT \
    --wait

# just sleep for a bit to ensure everything is ready, add some better health and liveness checks to server in future
sleep 5s

echo "Running RPS test..."
chmod +x ./modules/vegeta/run/run.sh
./modules/vegeta/run/run.sh "$INGRESS_URL" "$RATE" "$DURATION" "$WORKERS"
