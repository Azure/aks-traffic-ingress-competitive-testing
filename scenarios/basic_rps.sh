#!/bin/bash

set -e

# Function to show usage
show_usage() {
    echo "Usage: Set environment variables and run the script"
    echo ""
    echo "Required environment variables:"
    echo "  INGRESS_CLASS: The ingress class to test (e.g., nginx, traefik, istio)"
    echo "  INGRESS_URL: The URL to send requests to (e.g., http://example.com)"
    echo "  RATE: The rate of requests per second (e.g., 50)"
    echo "  DURATION: The duration of the test (e.g., 30s)"
    echo "  WORKERS: The number of worker processes to use (e.g., 10)"
    echo "  REPLICA_COUNT: The number of replicas for the server deployment (e.g., 3)"
    echo ""
    echo "Example:"
    echo "  INGRESS_CLASS=nginx INGRESS_URL=http://localhost:8080 RATE=50 DURATION=30s WORKERS=10 REPLICA_COUNT=3 $0"
    exit 1
}

# Set defaults if not provided
INGRESS_CLASS=${INGRESS_CLASS:-"nginx"}
INGRESS_URL=${INGRESS_URL:-""}
RATE=${RATE:-"50"}
DURATION=${DURATION:-"30s"}
WORKERS=${WORKERS:-"10"}
REPLICA_COUNT=${REPLICA_COUNT:-"3"}

# Validate required parameters
missing_params=()
[ -z "$INGRESS_URL" ] && missing_params+=("INGRESS_URL")

if [ ${#missing_params[@]} -gt 0 ]; then
    echo "Error: Missing required environment variables: ${missing_params[*]}"
    show_usage
fi

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

echo "Generating test results..."
mkdir -p ./scenarios/result
chmod +x ./modules/vegeta/output/output.sh
./modules/vegeta/output/output.sh > ./scenarios/result/basic_rps_result.json

echo "Test results saved to ./scenarios/result/basic_rps_result.json"
