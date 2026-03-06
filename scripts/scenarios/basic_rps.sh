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
    echo "  DURATION: The duration of the test (default: 30s)"
    echo "  WORKERS: The number of worker processes to use (default: 10)"
    echo "  OUTPUT_FILE: The file to save the test results (default: ./scenarios/results/basic_rps.json)"
    echo "  REQUEST_HEADERS: Additional request headers"
    echo ""
    echo "Example:"
    echo "  INGRESS_URL=http://localhost:8080 RATE=50 DURATION=30s WORKERS=10 OUTPUT_FILE=./scenarios/results/basic_rps.json $0"
    exit 1
}

# Set defaults if not provided
INGRESS_URL=${INGRESS_URL:-""}
RATE=${RATE:-"50"}
DURATION=${DURATION:-"30s"}
WORKERS=${WORKERS:-"10"}
OUTPUT_FILE=${OUTPUT_FILE:-"./scenarios/results/basic_rps.json"}
REQUEST_HEADERS=${REQUEST_HEADERS:-""}

# Validate required parameters
missing_params=()
[ -z "$INGRESS_URL" ] && missing_params+=("INGRESS_URL")

if [ ${#missing_params[@]} -gt 0 ]; then
    echo "Error: Missing required environment variables: ${missing_params[*]}"
    show_usage
fi

echo "Starting basic RPS test with:"
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
./modules/vegeta/run/run.sh "$INGRESS_URL" "$RATE" "$DURATION" "$WORKERS" "$REQUEST_HEADERS"

echo "Generating test results..."
mkdir -p "$(dirname "${OUTPUT_FILE}")"
chmod +x ./modules/vegeta/output/output.sh
./modules/vegeta/output/output.sh > "$OUTPUT_FILE"

echo "Test results saved to $OUTPUT_FILE"
