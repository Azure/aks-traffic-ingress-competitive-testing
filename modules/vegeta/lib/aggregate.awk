# Per-second bucketing of vegeta CSV records into JSON output.
#
# Used by both modules/vegeta/run/run.sh (live streaming during an attack) and
# modules/vegeta/merge/merge.sh (post-hoc merge of multiple .bin files).
#
# Input: rows from `vegeta encode --to csv`. Columns:
#   timestamp_ns, status_code, latency_ns, bytes_out, bytes_in, error
#
# Output: one JSON line per second-bucket, with shape:
#   {"rps":N,
#    "responded_count":R_n,"response_rate":R_r,
#    "successful_count":M,"success_rate":S_r,
#    "code":{"hist":{...exact codes...},"family":{"0":A,"100":B,"200":C,"300":D,"400":E,"500":F}},
#    "latency":{"p25":x,"p50":y,"p99":z},
#    "bytes_in":{"sum":...},"bytes_out":{"sum":...}}
#
# Two distinct count/rate pairs describe the request lifecycle:
#
#   responded_count / response_rate  — out of the rps requests sent this second,
#     how many came back as a non-0 status (server actually responded). Latency
#     percentiles are computed over these records — any non-zero status is a real
#     measurement of server response time, regardless of HTTP outcome. Code-0
#     transport failures (connection refused, EOF, timeout) are excluded because
#     their "latency" is failure-detection time, often the full --timeout, and
#     would skew percentiles. response_rate = responded_count / rps.
#
#   successful_count / success_rate  — out of the responded_count records that
#     came back, how many were 2xx (server accepted and fulfilled the request).
#     1xx interim, 3xx redirects, 4xx client errors, and 5xx server errors are
#     NOT counted as successful. success_rate = successful_count / responded_count,
#     or 0 when responded_count is 0 (no responses at all).
#
# code.hist preserves the exact status codes seen this second (e.g. "200":5,"503":2).
# code.family aggregates the same counts into hundreds families (0, 100, 200, 300,
# 400, 500) and always emits all six keys — the stable schema downstream plotters
# (jplot etc.) need so series don't disappear when a controller's exact codes vary.
# Both views describe the same records: sum(code.hist[*]) == sum(code.family[*]) == rps.
#
# response_rate and success_rate are floats in [0,1], formatted to 4 decimals.
#
# rps, code.hist, code.family, bytes_in.sum, bytes_out.sum count every record.
#
# Bucketing assumes records arrive roughly in timestamp order. The merge path
# sorts explicitly; the live path relies on `vegeta encode` emitting records in
# attack order (verified to be timestamp-sorted for steady-rate attacks). When
# a late record arrives (this_second < current_second), it is absorbed into the
# current bucket rather than triggering a new bucket flush — preventing the
# same wall-second from appearing on two output lines under high-variance load.

function floor_val(x) {
    return int(x)
}

function flush_bucket() {
    if (bucket_count == 0) return

    if (responded_count > 0) {
        asort(latencies, sorted_lat)
        n = responded_count
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

    # Aggregate exact codes into hundreds families. Always emit all 6 keys
    # (0, 100, 200, 300, 400, 500) so downstream plotters see a stable schema
    # regardless of which exact codes appeared this second.
    delete family_counts
    for (code in code_counts) {
        fam = int(code / 100) * 100
        family_counts[fam] += code_counts[code]
    }
    code_family = ""
    for (fam = 0; fam <= 500; fam += 100) {
        if (code_family != "") code_family = code_family ","
        cnt = (fam in family_counts) ? family_counts[fam] : 0
        code_family = code_family "\"" fam "\":" cnt
    }

    response_rate = responded_count / bucket_count
    if (responded_count > 0) {
        success_rate = successful_count / responded_count
    } else {
        success_rate = 0
    }

    printf "{\"rps\":%d,\"responded_count\":%d,\"response_rate\":%.4f,\"successful_count\":%d,\"success_rate\":%.4f,\"code\":{\"hist\":{%s},\"family\":{%s}},\"latency\":{\"p25\":%d,\"p50\":%d,\"p99\":%d},\"bytes_in\":{\"sum\":%d},\"bytes_out\":{\"sum\":%d}}\n", \
        bucket_count, responded_count, response_rate, successful_count, success_rate, code_hist, code_family, p25_val, p50_val, p99_val, bytes_in_sum, bytes_out_sum
    fflush()
}

BEGIN {
    FS = ","
    current_second = -1
    bucket_count = 0
    responded_count = 0
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

    if (this_second > current_second) {
        flush_bucket()
        current_second = this_second
        bucket_count = 0
        responded_count = 0
        successful_count = 0
        bytes_in_sum = 0
        bytes_out_sum = 0
        delete code_counts
        delete latencies
    }
    # Late record (this_second < current_second): absorb into the current
    # bucket rather than flushing and starting a new one. Splitting a second
    # into two output lines is worse than slight count drift across buckets.

    bucket_count++
    # Any non-0 status means the server actually responded — its latency is a
    # real measurement of server responsiveness regardless of HTTP outcome.
    if (status_code != "0") {
        responded_count++
        latencies[responded_count] = latency_ns + 0
    }
    # Successful means the server accepted and fulfilled the request: 2xx only.
    # 3xx redirects, 4xx client errors, and 5xx server errors don't count.
    if (int(status_code / 100) == 2) {
        successful_count++
    }
    code_counts[status_code] += 1
    bytes_in_sum += bytes_in + 0
    bytes_out_sum += bytes_out + 0
}

END {
    flush_bucket()
}
