#!/bin/bash

# Script to run Vegeta HTTP load testing attacks
# https://github.com/tsenart/vegeta

set -ex

filepath=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
statefile="${filepath}/../statefile.json"

function run_vegeta_attack() {
    local target_url="${1}"
    if [ -z "$target_url" ]; then
        echo "Usage: $0 <target_url> [rate] [duration] [workers]"
        echo "Example: ./modules/vegeta/run/run.sh http://localhost:8080 50 30s 10"
        return 1
    fi
    local rate="${2:-50}"        # requests per second, default 50
    local duration="${3:-30s}"   # duration of test, default 30s
    local workers="${4:-10}"     # number of workers, default 10
    local headers="${5:-}"    # additional request headers, default empty

    echo "Running Vegeta attack with:"
    echo "- Target URL: $target_url"
    echo "- Rate: $rate requests/second"
    echo "- Duration: $duration"
    echo "- Workers: $workers"
    echo "- Headers: $headers"
    


    # Run attack and generate report
    if [ -n "$headers" ]; then
        echo "Using additional headers: $headers"
        echo "GET $target_url" | \
        vegeta attack \
            -rate=$rate \
            -duration=$duration \
            -workers=$workers \
            -header "$headers" | \
        vegeta encode |\
        jaggr @count=rps \
          hist\[100,200,300,400,500\]:code \
          p25,p50,p99:latency \
          sum:bytes_in \
          sum:bytes_out |\
        tee $statefile
    else 
        echo "No additional headers provided."
        echo "GET $target_url" | \
        vegeta attack \
            -rate=$rate \
            -duration=$duration \
            -workers=$workers | \
        vegeta encode |\
        jaggr @count=rps \
          hist\[100,200,300,400,500\]:code \
          p25,p50,p99:latency \
          sum:bytes_in \
          sum:bytes_out |\
        tee $statefile
    fi
}

# If script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_vegeta_attack "$@"
fi