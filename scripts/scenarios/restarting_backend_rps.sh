#!/bin/bash

set -ex

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Runs an RPS load test while periodically restarting backend pods."
    echo ""
    echo "Required:"
    echo "  --ingress-url       The URL to send requests to (e.g., http://localhost:8080)"
    echo ""
    echo "Optional:"
    echo "  --rate              The rate of requests per second (default: 50)"
    echo "  --duration          The duration of the test (default: 90s)"
    echo "  --workers           The number of worker processes to use (optional; uses vegeta default if omitted)"
    echo "  --output-file       The file to save the test results (default: ./results/restarting_backend_rps.json)"
    echo "  --request-headers   Additional request headers"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --ingress-url http://localhost:8080 --rate 50 --duration 90s"
    exit 1
}

# Defaults (env vars supported for backward compatibility)
INGRESS_URL=${INGRESS_URL:-""}
RATE=${RATE:-"50"}
DURATION=${DURATION:-"90s"}
WORKERS=${WORKERS:-""}
OUTPUT_FILE=${OUTPUT_FILE:-"./results/restarting_backend_rps.json"}
REQUEST_HEADERS=${REQUEST_HEADERS:-""}

# Parse arguments (override env vars if provided)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ingress-url)
            INGRESS_URL="$2"
            shift 2
            ;;
        --rate)
            RATE="$2"
            shift 2
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --workers)
            WORKERS="$2"
            shift 2
            ;;
        --output-file)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --request-headers)
            REQUEST_HEADERS="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            ;;
        *)
            echo "Error: Unknown option: $1"
            show_usage
            ;;
    esac
done

# Validate required parameters
if [ -z "$INGRESS_URL" ]; then
    echo "Error: --ingress-url is required"
    show_usage
fi

echo "Starting restarting backend RPS test with:"
echo "  Ingress URL: $INGRESS_URL"
echo "  Rate: $RATE"
echo "  Duration: $DURATION"
echo "  Workers: ${WORKERS:-"(vegeta default)"}"
echo "  Output File: $OUTPUT_FILE"
echo "  Request Headers: $REQUEST_HEADERS"

echo "Install dependencies..."
chmod +x ./modules/vegeta/install/install.sh
./modules/vegeta/install/install.sh

echo "Running RPS test..."
chmod +x ./modules/vegeta/run/run.sh
VEGETA_ARGS=(
    --target-url "$INGRESS_URL"
    --rate "$RATE"
    --duration "$DURATION"
)

if [ -n "$WORKERS" ]; then
    VEGETA_ARGS+=(--workers "$WORKERS")
fi

if [ -n "$REQUEST_HEADERS" ]; then
    VEGETA_ARGS+=(--request-headers "$REQUEST_HEADERS")
fi

./modules/vegeta/run/run.sh "${VEGETA_ARGS[@]}" &
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
