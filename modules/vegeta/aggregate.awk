# Per-second bucketing of vegeta CSV records into JSON output.
#
# Used by both modules/vegeta/run/run.sh (live streaming during an attack) and
# modules/vegeta/merge/merge.sh (post-hoc merge of multiple .bin files).
#
# Input: rows from `vegeta encode --to csv`. Columns:
#   timestamp_ns, status_code, latency_ns, bytes_out, bytes_in, error
#
# Output: one JSON line per second-bucket, with shape:
#   {"rps":N,"successful_count":M,"success_rate":R,
#    "code":{"hist":{...}},
#    "latency":{"p25":x,"p50":y,"p99":z},
#    "bytes_in":{"sum":...},"bytes_out":{"sum":...}}
#
# Latency percentiles are computed over successful requests only (status_code != "0").
# Vegeta uses status_code=0 for transport-level failures (connection refused, EOF,
# timeout) — including those would skew percentiles toward the failure-detection time
# (often the full --timeout) when error rate is non-trivial.
#
# rps, code.hist, bytes_in.sum, bytes_out.sum count every record so that
# sum(code.hist[*]) == rps remains an invariant.
#
# success_rate is successful_count / rps as a float in [0,1], formatted to 4 decimals.
#
# Bucketing assumes records arrive roughly in timestamp order. The merge path sorts
# explicitly; the live path relies on `vegeta encode` emitting records in attack order
# (verified to be timestamp-sorted for steady-rate attacks).

function floor_val(x) {
    return int(x)
}

function flush_bucket() {
    if (bucket_count == 0) return

    if (successful_count > 0) {
        asort(latencies, sorted_lat)
        n = successful_count
        p25_idx = floor_val(n * 0.25); if (p25_idx < 1) p25_idx = 1
        p50_idx = floor_val(n * 0.50); if (p50_idx < 1) p50_idx = 1
        p99_idx = floor_val(n * 0.99); if (p99_idx < 1) p99_idx = 1
        p25_val = sorted_lat[p25_idx]
        p50_val = sorted_lat[p50_idx]
        p99_val = sorted_lat[p99_idx]
    } else {
        p25_val = 0; p50_val = 0; p99_val = 0
    }

    code_hist = ""
    for (code in code_counts) {
        if (code_hist != "") code_hist = code_hist ","
        code_hist = code_hist "\"" code "\":" code_counts[code]
    }

    success_rate = successful_count / bucket_count

    printf "{\"rps\":%d,\"successful_count\":%d,\"success_rate\":%.4f,\"code\":{\"hist\":{%s}},\"latency\":{\"p25\":%d,\"p50\":%d,\"p99\":%d},\"bytes_in\":{\"sum\":%d},\"bytes_out\":{\"sum\":%d}}\n", \
        bucket_count, successful_count, success_rate, code_hist, p25_val, p50_val, p99_val, bytes_in_sum, bytes_out_sum
    fflush()
}

BEGIN {
    FS = ","
    current_second = -1
    bucket_count = 0
    successful_count = 0
    bytes_in_sum = 0
    bytes_out_sum = 0
}

{
    timestamp_ns = $1
    status_code = $2
    latency_ns = $3
    bytes_out = $4
    bytes_in = $5

    this_second = floor_val(timestamp_ns / 1000000000)

    if (current_second == -1) {
        current_second = this_second
    }

    if (this_second != current_second) {
        flush_bucket()
        current_second = this_second
        bucket_count = 0
        successful_count = 0
        bytes_in_sum = 0
        bytes_out_sum = 0
        delete code_counts
        delete latencies
    }

    bucket_count++
    if (status_code != "0") {
        successful_count++
        latencies[successful_count] = latency_ns + 0
    }
    code_counts[status_code] += 1
    bytes_in_sum += bytes_in + 0
    bytes_out_sum += bytes_out + 0
}

END {
    flush_bucket()
}
