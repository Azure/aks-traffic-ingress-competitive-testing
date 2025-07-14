#!/bin/bash

set -e

# Function to show usage
show_usage() {
    echo "Usage: echo '{\"ingress_class\": \"nginx\", \"ingress_url\": \"http://example.com\", \"rate\": \"50\", \"duration\": \"30s\", \"workers\": \"10\", \"replica_count\": \"3\"}' | $0"
    echo ""
    echo "Required JSON fields:"
    echo "  ingress_class: The ingress class to test (e.g., nginx, traefik, istio)"
    echo "  ingress_url: The URL to send requests to (e.g., http://example.com)"
    echo "  rate: The rate of requests per second (e.g., 50)"
    echo "  duration: The duration of the test (e.g., 30s)"
    echo "  workers: The number of worker processes to use (e.g., 10)"
    echo "  replica_count: The number of replicas for the server deployment (e.g., 3)"
    exit 1
}

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Please install jq first."
    exit 1
fi

# Read JSON from stdin
if [ -t 0 ]; then
    echo "Error: No JSON input provided via stdin"
    show_usage
fi

# Read all input at once
input_json=$(cat)

# Validate JSON format
if ! echo "$input_json" | jq empty 2>/dev/null; then
    echo "Error: Invalid JSON format"
    show_usage
fi

# Extract parameters using jq
INGRESS_CLASS=$(echo "$input_json" | jq -r '.ingress_class // empty')
INGRESS_URL=$(echo "$input_json" | jq -r '.ingress_url // empty')
RATE=$(echo "$input_json" | jq -r '.rate // empty')
DURATION=$(echo "$input_json" | jq -r '.duration // empty')
WORKERS=$(echo "$input_json" | jq -r '.workers // empty')
REPLICA_COUNT=$(echo "$input_json" | jq -r '.replica_count // empty')

# Validate required parameters
missing_params=()
[ -z "$INGRESS_CLASS" ] && missing_params+=("ingress_class")
[ -z "$INGRESS_URL" ] && missing_params+=("ingress_url")
[ -z "$RATE" ] && missing_params+=("rate")
[ -z "$DURATION" ] && missing_params+=("duration")
[ -z "$WORKERS" ] && missing_params+=("workers")
[ -z "$REPLICA_COUNT" ] && missing_params+=("replica_count")

if [ ${#missing_params[@]} -gt 0 ]; then
    echo "Error: Missing required parameters: ${missing_params[*]}"
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
