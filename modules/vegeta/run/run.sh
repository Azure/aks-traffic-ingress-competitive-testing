#!/bin/bash

# Script to run Vegeta HTTP load testing attacks
# https://github.com/tsenart/vegeta

set -ex

filepath=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
statefile="${filepath}/../statefile.json"

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Runs a Vegeta HTTP load test against a target URL."
    echo ""
    echo "Required:"
    echo "  --target-url        The URL to send requests to (e.g., http://localhost:8080)"
    echo ""
    echo "Optional:"
    echo "  --rate              The rate of requests per second (default: 50)"
    echo "  --duration          The duration of the test (default: 30s)"
    echo "  --workers           The number of worker processes to use (optional; uses vegeta default if omitted)"
    echo "  --request-headers   Additional request headers"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --target-url http://localhost:8080 --rate 50 --duration 30s"
    echo "  $0 --target-url http://localhost:8080 --rate 50 --duration 30s --workers 20"
    echo "  $0 --target-url http://localhost:8080 --rate 50 --duration 30s --request-headers 'X-Test-Header: header-only'"
    echo "  $0 --target-url http://localhost:8080 --rate 50 --duration 30s --workers 20 --request-headers 'X-Test-Header: with-workers'"
    echo ""
    echo "Positional arguments are not supported."
}

run_vegeta_attack() {
    local target_url=""
    local rate="50"
    local duration="30s"
    local workers=""
    local headers=""
    local temp_results=""

    # Cleanup function to remove temp file on exit
    cleanup() {
        if [ -n "$temp_results" ] && [ -f "$temp_results" ]; then
            rm -f "$temp_results"
        fi
    }
    trap cleanup EXIT

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target-url)
                target_url="$2"
                shift 2
                ;;
            --rate)
                rate="$2"
                shift 2
                ;;
            --duration)
                duration="$2"
                shift 2
                ;;
            --workers)
                workers="$2"
                shift 2
                ;;
            --request-headers)
                headers="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                return 0
                ;;
            *)
                echo "Error: Unknown option: $1"
                show_usage
                return 1
                ;;
        esac
    done

    if [ -z "$target_url" ]; then
        echo "Error: --target-url is required"
        show_usage
        return 1
    fi

    echo "Running Vegeta attack with:"
    echo "- Target URL: $target_url"
    echo "- Rate: $rate requests/second"
    echo "- Duration: $duration"
    echo "- Workers: ${workers:-"(vegeta default)"}"
    echo "- Headers: $headers"

    local attack_cmd=("vegeta" "attack" "-rate=$rate" "-duration=$duration")
    if [ -n "$workers" ]; then
        attack_cmd+=("-workers=$workers")
    fi

    if [ -n "$headers" ]; then
        echo "Using additional headers: $headers"
        attack_cmd+=("-header" "$headers")
    else
        echo "No additional headers provided."
    fi

    # Run attack and generate report
    # Use a temp file to stream results to disk first, avoiding O(n) memory usage
    # This prevents OOM at high RPS (e.g., 20k RPS for 3 minutes = 3.6M requests)
    temp_results=$(mktemp)

    echo "Writing vegeta attack output to temp file: $temp_results"
    echo "GET $target_url" | \
    "${attack_cmd[@]}" > "$temp_results"

    echo "Processing results from disk..."
    vegeta encode < "$temp_results" | \
    jaggr @count=rps \
      hist\[100,200,300,400,500\]:code \
      p25,p50,p99:latency \
      sum:bytes_in \
      sum:bytes_out | \
    tee "$statefile"
}

# If script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_vegeta_attack "$@"
fi
