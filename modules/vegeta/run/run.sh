#!/bin/bash

# Script to run Vegeta HTTP load testing attacks
# https://github.com/tsenart/vegeta

set -ex

filepath=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
statefile="${filepath}/../statefile.json"

function run_vegeta_attack() {
    local target_url="${1}"
    if [ -z "$target_url" ]; then
        echo "Usage: $0 <target_url> [rate] [duration] [workers] [headers]"
        echo "Example: ./modules/vegeta/run/run.sh http://localhost:8080 50 30s"
        return 1
    fi
    local rate="${2:-50}"        # requests per second, default 50
    local duration="${3:-30s}"   # duration of test, default 30s
    local workers=""
    local headers=""

    if [ -n "${4:-}" ]; then
        if [[ "${4}" =~ ^[0-9]+$ ]]; then
            workers="${4}"
            headers="${5:-}"
        else
            headers="${4}"
        fi
    elif [ -n "${5:-}" ]; then
        headers="${5}"
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
    echo "GET $target_url" | \
    "${attack_cmd[@]}" | \
    vegeta encode |\
    jaggr @count=rps \
      hist\[100,200,300,400,500\]:code \
      p25,p50,p99:latency \
      sum:bytes_in \
      sum:bytes_out |\
    tee $statefile
}

# If script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_vegeta_attack "$@"
fi