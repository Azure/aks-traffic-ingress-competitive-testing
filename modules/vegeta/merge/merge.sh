#!/bin/bash

# Script to merge multiple vegeta raw .bin files into jaggr-format per-second JSON output.
# Uses actual request timestamps for bucketing (not wall-clock time), so it works correctly
# on saved/replayed data and correctly interleaves results from pods that started at
# slightly different times.
#
# The first and last second-buckets are dropped because timestamp-based bucketing produces
# partial edge buckets (vegeta doesn't start/stop exactly on second boundaries). Only
# complete interior buckets are emitted so results accurately represent the target load.

set -e

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
# 3. gawk to bucket by second and compute per-bucket aggregates
# 4. Drop first and last lines (partial edge buckets)
# 5. Output one JSON line per complete second-bucket
merge_results() {
    vegeta encode --to csv "${bin_files[@]}" | \
    sort -t, -k1,1n | \
    gawk -F, '
    function floor_val(x) {
        return int(x)
    }
    function flush_bucket() {
        if (bucket_count == 0) return

        # Compute latency percentiles
        asort(latencies, sorted_lat)
        n = bucket_count
        p25_idx = floor_val(n * 0.25)
        if (p25_idx < 1) p25_idx = 1
        p50_idx = floor_val(n * 0.50)
        if (p50_idx < 1) p50_idx = 1
        p99_idx = floor_val(n * 0.99)
        if (p99_idx < 1) p99_idx = 1

        p25_val = sorted_lat[p25_idx]
        p50_val = sorted_lat[p50_idx]
        p99_val = sorted_lat[p99_idx]

        # Build code histogram JSON
        code_hist = ""
        for (code in code_counts) {
            if (code_hist != "") code_hist = code_hist ","
            code_hist = code_hist "\"" code "\":" code_counts[code]
        }

        printf "{\"rps\":%d,\"code\":{\"hist\":{%s}},\"latency\":{\"p25\":%s,\"p50\":%s,\"p99\":%s},\"bytes_in\":{\"sum\":%s},\"bytes_out\":{\"sum\":%s}}\n", \
            bucket_count, code_hist, p25_val, p50_val, p99_val, bytes_in_sum, bytes_out_sum
    }

    BEGIN {
        current_second = -1
        bucket_count = 0
        bytes_in_sum = 0
        bytes_out_sum = 0
    }

    {
        # CSV columns: timestamp_ns, status_code, latency_ns, bytes_out, bytes_in, error
        timestamp_ns = $1
        status_code = $2
        latency_ns = $3
        bytes_out = $4
        bytes_in = $5

        # Bucket by second (integer division of nanoseconds by 1e9)
        this_second = floor_val(timestamp_ns / 1000000000)

        if (current_second == -1) {
            current_second = this_second
        }

        if (this_second != current_second) {
            flush_bucket()

            # Reset for new bucket
            current_second = this_second
            bucket_count = 0
            bytes_in_sum = 0
            bytes_out_sum = 0
            delete code_counts
            delete latencies
        }

        bucket_count++
        latencies[bucket_count] = latency_ns + 0
        code_counts[status_code] += 1
        bytes_in_sum += bytes_in + 0
        bytes_out_sum += bytes_out + 0
    }

    END {
        flush_bucket()
    }
    ' | \
    sed '1d;$d'
}

if [[ -n "$output_file" ]]; then
    merge_results > "$output_file"
    echo "Merged output written to ${output_file}" >&2
else
    merge_results
fi
