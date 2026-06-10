#!/bin/bash

# Script to merge multiple vegeta raw .bin files into jaggr-format per-second JSON output.
# Uses actual request timestamps for bucketing (not wall-clock time), so it works correctly
# on saved/replayed data and correctly interleaves results from pods that started at
# slightly different times.
#
# Note: The first and last second-buckets may be partial (vegeta doesn't start/stop exactly
# on second boundaries). Consumers should account for this when validating RPS values.

set -eo pipefail

filepath=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
aggregator="${filepath}/../aggregate.awk"

show_usage() {
    echo "Usage: $0 [--output-file FILE] <bin_file1> [bin_file2 ...]"
    echo ""
    echo "Merges one or more raw vegeta .bin files into jaggr-format per-second JSON output."
    echo ""
    echo "Options:"
    echo "  --output-file FILE   Write output to FILE (default: stdout)"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 results/pod0.bin results/pod1.bin"
    echo "  $0 --output-file merged.json results/pod0.bin results/pod1.bin results/pod2.bin"
    echo "  $0 results/single.bin"
}

output_file=""
bin_files=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-file)
            output_file="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            echo "Error: Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            bin_files+=("$1")
            shift
            ;;
    esac
done

if [[ ${#bin_files[@]} -eq 0 ]]; then
    echo "Error: At least one .bin file is required"
    show_usage
    exit 1
fi

# Validate all input files exist and are non-empty
for f in "${bin_files[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "Error: File not found: $f"
        exit 1
    fi
    if [[ ! -s "$f" ]]; then
        echo "Error: File is empty: $f"
        exit 1
    fi
done

echo "Merging ${#bin_files[@]} .bin file(s)..." >&2

# Pipeline:
# 1. vegeta encode --to csv on all input files (vegeta round-robins through them)
# 2. Sort by timestamp column (column 1, nanoseconds since epoch)
# 3. gawk (shared aggregate.awk) to bucket by second and compute per-bucket aggregates
# 4. Output one JSON line per second-bucket
merge_results() {
    vegeta encode --to csv "${bin_files[@]}" | \
    sort -t, -k1,1n | \
    gawk -f "$aggregator"
}

if [[ -n "$output_file" ]]; then
    merge_results > "$output_file"
    echo "Merged output written to ${output_file}" >&2
else
    merge_results
fi
