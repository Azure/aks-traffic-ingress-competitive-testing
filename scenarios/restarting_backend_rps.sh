#!/bin/bash

set -ex

# Function to show usage
show_usage() {
    echo "Usage: Set environment variables and run the script"
    echo ""
    echo "Required environment variables:"
    echo "  INGRESS_CLASS: The ingress class to test (e.g., nginx, traefik, istio)"
    echo "  INGRESS_URL: The URL to send requests to (e.g., http://example.com)"
    echo "  RATE: The rate of requests per second (e.g., 50)"
    echo "  DURATION: The duration of the test (e.g., 90s)"
    echo "  WORKERS: The number of worker processes to use (e.g., 10)"
    echo "  REPLICA_COUNT: The number of replicas for the server deployment (e.g., 5)"
    echo "  OUTPUT_FILE: The file to save the test results (e.g., ./scenarios/results/restarting_backend_rps.json)"
    echo ""
    echo "Example:"
    echo "  INGRESS_CLASS=nginx INGRESS_URL=http://localhost:8080 RATE=50 DURATION=90s WORKERS=10 REPLICA_COUNT=5 OUTPUT_FILE=./scenarios/results/restarting_backend_rps.json $0"
    exit 1
}

# Set defaults if not provided
INGRESS_CLASS=${INGRESS_CLASS:-"nginx"}
INGRESS_URL=${INGRESS_URL:-""}
RATE=${RATE:-"50"}
DURATION=${DURATION:-"90s"}
WORKERS=${WORKERS:-"10"}
REPLICA_COUNT=${REPLICA_COUNT:-"5"}
OUTPUT_FILE=${OUTPUT_FILE:-"./scenarios/results/restarting_backend_rps.json"}
REQUEST_HEADERS=${REQUEST_HEADERS:-""}

# Validate required parameters
missing_params=()
[ -z "$INGRESS_URL" ] && missing_params+=("INGRESS_URL")

if [ ${#missing_params[@]} -gt 0 ]; then
    echo "Error: Missing required environment variables: ${missing_params[*]}"
    show_usage
fi

echo "Starting restarting backend RPS test with:"
echo "  Ingress Class: $INGRESS_CLASS"
echo "  Ingress URL: $INGRESS_URL"
echo "  Rate: $RATE"
echo "  Duration: $DURATION"
echo "  Workers: $WORKERS"
echo "  Replica Count: $REPLICA_COUNT"
echo "  Output File: $OUTPUT_FILE"
echo "  Request Headers: $REQUEST_HEADERS"

echo "Install dependencies..."
chmod +x ./modules/vegeta/install/install.sh
./modules/vegeta/install/install.sh

echo "Applying manifests..."
if [ "${SKIP_HELM_DEPLOYMENT:-false}" = "true" ]; then
    echo "Skipping Helm deployment - server already deployed by validation step"
else
    helm upgrade --install server ./charts/server \
        --namespace server \
        --create-namespace \
        --set ingress.enabled=true \
        --set ingress.className=$INGRESS_CLASS \
        --set replicaCount=$REPLICA_COUNT \
        --wait
fi

# just sleep for a bit to ensure everything is ready, add some better health and liveness checks to server in future
sleep 5s

echo "Running RPS test..."
chmod +x ./modules/vegeta/run/run.sh
./modules/vegeta/run/run.sh "$INGRESS_URL" "$RATE" "$DURATION" "$WORKERS" "$REQUEST_HEADERS" &
VEGETA_PID=$!

# Start restart loop
while kill -0 $VEGETA_PID 2>/dev/null; do
    sleep 10s

    echo "Restarting backend pods..."
    kubectl rollout restart deployment server -n server
    kubectl rollout status deployment server -n server
    echo "Rollout completed."
done

wait $VEGETA_PID

echo "Generating test results..."
mkdir -p "$(dirname "${OUTPUT_FILE}")"
chmod +x ./modules/vegeta/output/output.sh
./modules/vegeta/output/output.sh > "$OUTPUT_FILE"

echo "Test results saved to $OUTPUT_FILE"