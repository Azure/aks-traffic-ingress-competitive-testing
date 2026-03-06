#!/bin/bash

set -ex

# Function to show usage
show_usage() {
    echo "Usage: Set environment variables and run the script"
    echo ""
    echo "Required environment variables:"
    echo "  INGRESS_URL: The URL to send requests to (e.g., http://example.com)"
    echo ""
    echo "Optional environment variables:"
    echo "  RATE: The rate of requests per second (default: 50)"
    echo "  DURATION: The duration of the test (default: 90s)"
    echo "  WORKERS: The number of worker processes to use (default: 10)"
    echo "  OUTPUT_FILE: The file to save the test results (default: ./results/restarting_backend_rps.json)"
    echo "  REQUEST_HEADERS: Additional request headers"
    echo ""
    echo "Example:"
    echo "  INGRESS_URL=http://localhost:8080 RATE=50 DURATION=90s WORKERS=10 OUTPUT_FILE=./results/restarting_backend_rps.json $0"
    exit 1
}

# Set defaults if not provided
INGRESS_URL=${INGRESS_URL:-""}
RATE=${RATE:-"50"}
DURATION=${DURATION:-"90s"}
WORKERS=${WORKERS:-"10"}
OUTPUT_FILE=${OUTPUT_FILE:-"./results/restarting_backend_rps.json"}
REQUEST_HEADERS=${REQUEST_HEADERS:-""}

# Validate required parameters
missing_params=()
[ -z "$INGRESS_URL" ] && missing_params+=("INGRESS_URL")

if [ ${#missing_params[@]} -gt 0 ]; then
    echo "Error: Missing required environment variables: ${missing_params[*]}"
    show_usage
fi

echo "Starting restarting backend RPS test with:"
echo "  Ingress URL: $INGRESS_URL"
echo "  Rate: $RATE"
echo "  Duration: $DURATION"
echo "  Workers: $WORKERS"
echo "  Output File: $OUTPUT_FILE"
echo "  Request Headers: $REQUEST_HEADERS"

echo "Install dependencies..."
chmod +x ./modules/vegeta/install/install.sh
./modules/vegeta/install/install.sh

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