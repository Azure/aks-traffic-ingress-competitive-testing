#!/bin/bash

set -e

echo "Testing Vegeta module..."

# Get the module directory
MODULE_DIR=$( cd "$(dirname "${BASH_SOURCE[0]}")/.." ; pwd -P )
PROJECT_ROOT=$( cd "${MODULE_DIR}/../.." ; pwd -P )

# Test HTTP server setup
TEST_PORT="9999"
TEST_CONTAINER_NAME="vegeta-test-server"

# Cleanup function
cleanup() {
    echo "Cleaning up test environment..."

    # Stop and remove test container if running
    if docker ps -q -f name="${TEST_CONTAINER_NAME}" | grep -q .; then
        echo "Stopping test container..."
        docker stop "${TEST_CONTAINER_NAME}" > /dev/null 2>&1 || true
    fi

    if docker ps -aq -f name="${TEST_CONTAINER_NAME}" | grep -q .; then
        echo "Removing test container..."
        docker rm "${TEST_CONTAINER_NAME}" > /dev/null 2>&1 || true
    fi

    # Clean up any test state files
    rm -f "${MODULE_DIR}/statefile.json" || true
    rm -f "${MODULE_DIR}/statefile.bin" || true
    rm -f /tmp/vegeta-test-*.bin /tmp/vegeta-test-*.csv /tmp/vegeta-test-merge-*.json /tmp/vegeta-test-synthetic* /tmp/vegeta-test-latfilt-*.json /tmp/vegeta-test-allfam*.json || true
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Start a test HTTP server using Docker
start_test_server() {
    echo "Starting test HTTP server on port ${TEST_PORT} using Docker..."

    # Start the Docker container with the specified image
    docker run -d \
        --name "${TEST_CONTAINER_NAME}" \
        -p "${TEST_PORT}:${TEST_PORT}" \
        -e PORT="${TEST_PORT}" \
        ghcr.io/azure/aks-traffic-ingress-competitive-testing:8aba95806ff611e9939257e2c3c9f53b3af5f7a2 > /dev/null

    # Wait for server to start
    echo "Waiting for server to start..."
    sleep 5

    # Verify server is running
    for i in {1..10}; do
        if curl -s "http://localhost:${TEST_PORT}" > /dev/null; then
            echo "✓ Test server started successfully"
            return 0
        fi
        echo "Waiting for server to respond... (attempt $i/10)"
        sleep 2
    done

    echo "ERROR: Test server failed to start or respond"
    docker logs "${TEST_CONTAINER_NAME}" 2>&1 || true
    exit 1
}

echo "1. Testing Vegeta installation..."
chmod +x "${MODULE_DIR}/install/install.sh"

# Always run the install script to test the installation process
echo "Running Vegeta installation..."
"${MODULE_DIR}/install/install.sh"

# Verify Vegeta is installed
if ! command -v vegeta &> /dev/null; then
    echo "ERROR: Vegeta installation failed - vegeta command not found"
    exit 1
fi

echo "✓ Vegeta installation test passed"

echo "2. Testing Vegeta version..."
VEGETA_VERSION=$(vegeta --version)
echo "Vegeta version: ${VEGETA_VERSION}"

echo "✓ Version check test passed"

echo "3. Setting up test environment..."
start_test_server

echo "4. Testing Vegeta run script..."
chmod +x "${MODULE_DIR}/run/run.sh"

# Test the run script with a short attack
cd "${PROJECT_ROOT}"
"${MODULE_DIR}/run/run.sh" \
    --target-url "http://localhost:${TEST_PORT}" \
    --rate 50 \
    --duration 10s \
    --workers 2

# Verify statefile was created
STATEFILE="${MODULE_DIR}/statefile.json"
if [[ ! -f "${STATEFILE}" ]]; then
    echo "ERROR: State file was not created at ${STATEFILE}"
    exit 1
fi

echo "✓ Vegeta run test passed"

echo "5. Testing state file content..."
# Verify state file contains expected data
if [[ ! -s "${STATEFILE}" ]]; then
    echo "ERROR: State file is empty"
    exit 1
fi

# Check the state file contains the expected aggregator output format
if ! grep -q "rps" "${STATEFILE}"; then
    echo "ERROR: State file may not contain expected aggregator output format"
    echo "State file content:"
    cat "${STATEFILE}"
    exit 1
fi

# Check that the sum of status codes in the histogram equals the reported rps
# (validates every request was accounted for, regardless of status code)
while IFS= read -r line; do
    RPS_VAL=$(echo "$line" | jq -r '.rps')
    CODE_SUM=$(echo "$line" | jq -r '[.code.hist | to_entries[] | .value] | add // 0')
    if [[ "${CODE_SUM}" -ne "${RPS_VAL}" ]]; then
        echo "ERROR: Code histogram sum (${CODE_SUM}) does not match rps (${RPS_VAL})"
        echo "Line: ${line}"
        exit 1
    fi
done < "${STATEFILE}"
echo "✓ All status code histogram sums match reported rps"

echo "✓ State file content test passed"

echo "6. Testing output script..."
chmod +x "${MODULE_DIR}/output/output.sh"

# Test the output function
OUTPUT=$("${MODULE_DIR}/output/output.sh")
if [[ -z "${OUTPUT}" ]]; then
    echo "ERROR: Output script returned empty result"
    exit 1
fi

echo "Output script result:"
echo "${OUTPUT}"

echo "✓ Output script test passed"

echo "7. Testing error handling..."
# Test run script with missing parameters
if "${MODULE_DIR}/run/run.sh" > /dev/null 2>&1; then
    echo "ERROR: Expected failure with missing parameters, but command succeeded"
    exit 1
fi

echo "✓ Error handling test passed"

echo "8. Testing different attack parameters..."
# Test with different parameters
"${MODULE_DIR}/run/run.sh" \
    --target-url "http://localhost:${TEST_PORT}" \
    --rate 500 \
    --duration 20s \
    --workers 1

echo "✓ Parameter variation test passed"

echo "9. Testing header-only named invocation..."
HEADER_ONLY_OUTPUT=$("${MODULE_DIR}/run/run.sh" \
    --target-url "http://localhost:${TEST_PORT}" \
    --rate 500 \
    --duration 20s \
    --request-headers "X-Test-Header: header-only" 2>&1)
echo "Header-only output:"
printf '%s\n' "${HEADER_ONLY_OUTPUT}"

if ! printf '%s\n' "${HEADER_ONLY_OUTPUT}" | grep -Fq -- '- Workers: (vegeta default)'; then
    echo "ERROR: Expected header-only invocation to use vegeta default workers"
    echo "Command output:"
    echo "${HEADER_ONLY_OUTPUT}"
    exit 1
fi

if ! printf '%s\n' "${HEADER_ONLY_OUTPUT}" | grep -Fq -- '- Headers: X-Test-Header: header-only'; then
    echo "ERROR: Expected header-only invocation to preserve the headers value"
    echo "Command output:"
    echo "${HEADER_ONLY_OUTPUT}"
    exit 1
fi

echo "✓ Header-only invocation test passed"

echo "10. Testing workers plus headers named invocation..."
WORKERS_AND_HEADERS_OUTPUT=$("${MODULE_DIR}/run/run.sh" \
    --target-url "http://localhost:${TEST_PORT}" \
    --rate 500 \
    --duration 20s \
    --workers 1 \
    --request-headers "X-Test-Header: with-workers" 2>&1)
echo "Workers and headers output:"
printf '%s\n' "${WORKERS_AND_HEADERS_OUTPUT}"

if ! printf '%s\n' "${WORKERS_AND_HEADERS_OUTPUT}" | grep -Fq -- '- Workers: 1'; then
    echo "ERROR: Expected workers plus headers invocation to preserve the explicit workers value"
    echo "Command output:"
    echo "${WORKERS_AND_HEADERS_OUTPUT}"
    exit 1
fi

if ! printf '%s\n' "${WORKERS_AND_HEADERS_OUTPUT}" | grep -Fq -- '- Headers: X-Test-Header: with-workers'; then
    echo "ERROR: Expected workers plus headers invocation to preserve the headers value"
    echo "Command output:"
    echo "${WORKERS_AND_HEADERS_OUTPUT}"
    exit 1
fi

echo "✓ Workers plus headers invocation test passed"

echo "11. Testing positional invocation failure..."
set +e
POSITIONAL_OUTPUT=$("${MODULE_DIR}/run/run.sh" "http://localhost:${TEST_PORT}" 10 1s 1 2>&1)
POSITIONAL_STATUS=$?
set -e

echo "Positional invocation output:"
printf '%s\n' "${POSITIONAL_OUTPUT}"

if [[ "${POSITIONAL_STATUS}" -eq 0 ]]; then
    echo "ERROR: Expected old positional invocation to fail, but command succeeded"
    exit 1
fi

if ! printf '%s\n' "${POSITIONAL_OUTPUT}" | grep -Fq -- 'Positional arguments are not supported.'; then
    echo "ERROR: Expected positional invocation failure to explain that positional arguments are unsupported"
    echo "Command output:"
    echo "${POSITIONAL_OUTPUT}"
    exit 1
fi

echo "✓ Positional invocation failure test passed"

echo "12. Testing raw .bin file is produced alongside statefile..."
BINFILE="${MODULE_DIR}/statefile.bin"
if [[ ! -f "${BINFILE}" ]]; then
    echo "ERROR: Binary file was not created at ${BINFILE}"
    exit 1
fi

if [[ ! -s "${BINFILE}" ]]; then
    echo "ERROR: Binary file is empty"
    exit 1
fi

# Verify it's valid vegeta binary by running vegeta encode on it
if ! vegeta encode "${BINFILE}" | head -n 1 | jq . > /dev/null 2>&1; then
    echo "ERROR: Binary file is not valid vegeta binary format"
    exit 1
fi

echo "✓ Raw .bin file test passed"

echo "13. Testing per-second bucketing is correct..."
# Run a fresh attack with known rate and duration
rm -f "${STATEFILE}" "${BINFILE}"
"${MODULE_DIR}/run/run.sh" \
    --target-url "http://localhost:${TEST_PORT}" \
    --rate 50 \
    --duration 10s \
    --workers 2

# Count lines in statefile — a 10s test should produce ~10 lines (one per second)
# Allow some slack for edge effects on the first/last partial second
LINE_COUNT=$(wc -l < "${STATEFILE}")
echo "Statefile has ${LINE_COUNT} lines (second-buckets) for a 10s test"
if [[ "${LINE_COUNT}" -lt 8 ]]; then
    echo "ERROR: Expected at least 8 second-buckets for a 10s test, got ${LINE_COUNT}"
    echo "Statefile content:"
    cat "${STATEFILE}"
    exit 1
fi

# Check that each line's rps value is reasonable (roughly near 50, not collapsed or empty).
# Skip the first and last lines since they may be partial edge buckets — the attack rarely
# starts or stops exactly on a second boundary, so those buckets can legitimately be
# significantly below 50 RPS without indicating a bucketing bug. Mirrors test #14.
TOTAL_LINES=$(wc -l < "${STATEFILE}")
LINE_NUM=0
MIN_REASONABLE_RPS=38   # 0.75x the target rate
MAX_REASONABLE_RPS=63   # 1.25x the target rate
while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))
    RPS_VAL=$(echo "$line" | jq -r '.rps // 0')
    if [[ "${RPS_VAL}" -gt "${MAX_REASONABLE_RPS}" ]]; then
        echo "ERROR: RPS value ${RPS_VAL} is unreasonably high (expected near 50, max ${MAX_REASONABLE_RPS})"
        echo "This suggests results were collapsed instead of bucketed per-second"
        echo "Line: ${line}"
        exit 1
    fi
    # Skip RPS lower-bound check on first and last lines (partial edge buckets)
    if [[ "${LINE_NUM}" -eq 1 ]] || [[ "${LINE_NUM}" -eq "${TOTAL_LINES}" ]]; then
        continue
    fi
    if [[ "${RPS_VAL}" -lt "${MIN_REASONABLE_RPS}" ]]; then
        echo "ERROR: RPS value ${RPS_VAL} is unreasonably low (expected near 50, min ${MIN_REASONABLE_RPS})"
        echo "Line: ${line}"
        exit 1
    fi
done < "${STATEFILE}"

echo "✓ Per-second bucketing test passed"

echo "14. Testing merge.sh with a single .bin file..."
chmod +x "${MODULE_DIR}/merge/merge.sh"

# Run a vegeta attack to produce a .bin file
rm -f "${STATEFILE}" "${BINFILE}"
"${MODULE_DIR}/run/run.sh" \
    --target-url "http://localhost:${TEST_PORT}" \
    --rate 50 \
    --duration 10s \
    --workers 2

MERGE_OUTPUT="/tmp/vegeta-test-merge-single.json"
rm -f "${MERGE_OUTPUT}"

"${MODULE_DIR}/merge/merge.sh" --output-file "${MERGE_OUTPUT}" "${BINFILE}"

# Validate output file exists and is non-empty
if [[ ! -s "${MERGE_OUTPUT}" ]]; then
    echo "ERROR: Merge output file is empty or missing"
    exit 1
fi

# Validate each line is valid JSON with expected fields
while IFS= read -r line; do
    for field in rps "code" "latency" "bytes_in" "bytes_out"; do
        if ! echo "$line" | jq -e ".${field}" > /dev/null 2>&1; then
            echo "ERROR: Merge output line missing expected field '${field}'"
            echo "Line: ${line}"
            exit 1
        fi
    done
    # Check latency subfields
    for subfield in p25 p50 p99; do
        if ! echo "$line" | jq -e ".latency.${subfield}" > /dev/null 2>&1; then
            echo "ERROR: Merge output line missing latency.${subfield}"
            echo "Line: ${line}"
            exit 1
        fi
    done
done < "${MERGE_OUTPUT}"

# Verify line count roughly matches the 10s test duration
# The first and last second-buckets may be partial, so expect ~10 lines from a 10s test
MERGE_LINE_COUNT=$(wc -l < "${MERGE_OUTPUT}")
echo "Merge output has ${MERGE_LINE_COUNT} lines (second-buckets) for a 10s test"
if [[ "${MERGE_LINE_COUNT}" -lt 8 ]]; then
    echo "ERROR: Expected at least 8 second-buckets for a 10s test, got ${MERGE_LINE_COUNT}"
    cat "${MERGE_OUTPUT}"
    exit 1
fi

# Verify each line's code histogram sum matches rps
# Skip first and last lines when checking RPS bounds (they may be partial edge buckets)
MERGE_TOTAL_LINES=$(wc -l < "${MERGE_OUTPUT}")
MERGE_LINE_NUM=0
MIN_REASONABLE_RPS=38  # 0.75x the target rate
MAX_REASONABLE_RPS=63  # 1.25x the target rate
while IFS= read -r line; do
    MERGE_LINE_NUM=$((MERGE_LINE_NUM + 1))
    RPS_VAL=$(echo "$line" | jq -r '.rps // 0')
    CODE_SUM=$(echo "$line" | jq -r '[.code.hist | to_entries[] | .value] | add // 0')
    if [[ "${CODE_SUM}" -ne "${RPS_VAL}" ]]; then
        echo "ERROR: Merge code histogram sum (${CODE_SUM}) does not match rps (${RPS_VAL})"
        echo "Line: ${line}"
        exit 1
    fi
    # Skip RPS bounds check on first and last lines (partial edge buckets)
    if [[ "${MERGE_LINE_NUM}" -eq 1 ]] || [[ "${MERGE_LINE_NUM}" -eq "${MERGE_TOTAL_LINES}" ]]; then
        continue
    fi
    if [[ "${RPS_VAL}" -gt "${MAX_REASONABLE_RPS}" ]]; then
        echo "ERROR: Merge RPS value ${RPS_VAL} is unreasonably high (expected near 50, max ${MAX_REASONABLE_RPS})"
        echo "This suggests results were collapsed instead of bucketed per-second"
        echo "Line: ${line}"
        exit 1
    fi
    if [[ "${RPS_VAL}" -lt "${MIN_REASONABLE_RPS}" ]]; then
        echo "ERROR: Merge RPS value ${RPS_VAL} is unreasonably low (expected near 50, min ${MIN_REASONABLE_RPS})"
        echo "Line: ${line}"
        exit 1
    fi
done < "${MERGE_OUTPUT}"

echo "✓ Merge single .bin file test passed"

echo "15. Testing merge.sh combining multiple simultaneous .bin files..."
# Run two vegeta attacks in parallel so their timestamps actually overlap
BIN_FILE_1="/tmp/vegeta-test-attack1.bin"
BIN_FILE_2="/tmp/vegeta-test-attack2.bin"
rm -f "${BIN_FILE_1}" "${BIN_FILE_2}"

# Launch both attacks simultaneously in background
echo "GET http://localhost:${TEST_PORT}" | \
    vegeta attack -rate=50 -duration=10s -workers=2 > "${BIN_FILE_1}" &
PID1=$!

echo "GET http://localhost:${TEST_PORT}" | \
    vegeta attack -rate=50 -duration=10s -workers=2 > "${BIN_FILE_2}" &
PID2=$!

# Wait for both to finish
wait "$PID1" "$PID2"

# Verify both produced output
if [[ ! -s "${BIN_FILE_1}" ]]; then
    echo "ERROR: Attack 1 produced no output"
    exit 1
fi
if [[ ! -s "${BIN_FILE_2}" ]]; then
    echo "ERROR: Attack 2 produced no output"
    exit 1
fi

# Run merge.sh on both files without --output-file, capture stdout
MULTI_MERGE_OUTPUT=$("${MODULE_DIR}/merge/merge.sh" "${BIN_FILE_1}" "${BIN_FILE_2}")

# Verify line count roughly matches the 10s test duration
# The first and last second-buckets may be partial, so expect ~10 lines from a 10s test
MULTI_MERGE_LINE_COUNT=$(echo "$MULTI_MERGE_OUTPUT" | wc -l)
echo "Multi-file merge output has ${MULTI_MERGE_LINE_COUNT} lines (second-buckets) for a 10s test"
if [[ "${MULTI_MERGE_LINE_COUNT}" -lt 8 ]]; then
    echo "ERROR: Expected at least 8 second-buckets for a 10s test, got ${MULTI_MERGE_LINE_COUNT}"
    echo "$MULTI_MERGE_OUTPUT"
    exit 1
fi

# Verify each line's code histogram sum matches rps
# Skip first and last lines when checking RPS bounds (they may be partial edge buckets)
MULTI_TOTAL_LINES=$(echo "$MULTI_MERGE_OUTPUT" | wc -l)
MULTI_LINE_NUM=0
MIN_REASONABLE_RPS=75   # 0.75x the combined target rate of ~100
MAX_REASONABLE_RPS=125  # 1.25x the combined target rate of ~100
while IFS= read -r line; do
    MULTI_LINE_NUM=$((MULTI_LINE_NUM + 1))
    RPS_VAL=$(echo "$line" | jq -r '.rps // 0')
    CODE_SUM=$(echo "$line" | jq -r '[.code.hist | to_entries[] | .value] | add // 0')
    if [[ "${CODE_SUM}" -ne "${RPS_VAL}" ]]; then
        echo "ERROR: Multi-merge code histogram sum (${CODE_SUM}) does not match rps (${RPS_VAL})"
        echo "Line: ${line}"
        exit 1
    fi
    # Skip RPS bounds check on first and last lines (partial edge buckets)
    if [[ "${MULTI_LINE_NUM}" -eq 1 ]] || [[ "${MULTI_LINE_NUM}" -eq "${MULTI_TOTAL_LINES}" ]]; then
        continue
    fi
    if [[ "${RPS_VAL}" -gt "${MAX_REASONABLE_RPS}" ]]; then
        echo "ERROR: Multi-merge RPS value ${RPS_VAL} is unreasonably high (expected near 100, max ${MAX_REASONABLE_RPS})"
        echo "This suggests results were collapsed instead of bucketed per-second"
        echo "Line: ${line}"
        exit 1
    fi
    if [[ "${RPS_VAL}" -lt "${MIN_REASONABLE_RPS}" ]]; then
        echo "ERROR: Multi-merge RPS value ${RPS_VAL} is unreasonably low (expected near 100, min ${MIN_REASONABLE_RPS})"
        echo "Line: ${line}"
        exit 1
    fi
done <<< "$MULTI_MERGE_OUTPUT"

echo "✓ Merge multiple simultaneous .bin files test passed"

echo "16. Testing merge.sh latency percentile logic with multi-pod synthetic data..."
# Simulate two pods attacking the same server by creating two separate .bin files
# with overlapping timestamps in the same second-buckets. This verifies that merge.sh
# correctly interleaves requests from multiple sources and computes accurate percentiles
# across the combined data.
#
# Strategy: Each pod produces 3 second-buckets (edge, interior, edge).
# The interior bucket (second 1) will contain the combined requests from both pods.
# The edge buckets (seconds 0 and 2) have fewer requests and are expected to be partial.
#
# Pod A interior bucket: 50 requests with latencies 1ms, 3ms, 5ms, ..., 99ms (odd ms)
# Pod B interior bucket: 50 requests with latencies 2ms, 4ms, 6ms, ..., 100ms (even ms)
# Combined: 100 requests with latencies 1ms, 2ms, 3ms, ..., 100ms
#
# Expected percentiles for the interior bucket:
#   p25 = sorted[int(100 * 0.25)] = sorted[25] = 25ms = 25000000ns
#   p50 = sorted[int(100 * 0.50)] = sorted[50] = 50ms = 50000000ns
#   p99 = sorted[int(100 * 0.99)] = sorted[99] = 99ms = 99000000ns

SYNTHETIC_CSV_A="/tmp/vegeta-test-synthetic-a.csv"
SYNTHETIC_CSV_B="/tmp/vegeta-test-synthetic-b.csv"
SYNTHETIC_BIN_A="/tmp/vegeta-test-synthetic-a.bin"
SYNTHETIC_BIN_B="/tmp/vegeta-test-synthetic-b.bin"
SYNTHETIC_OUT="/tmp/vegeta-test-synthetic-merged.json"
rm -f "${SYNTHETIC_CSV_A}" "${SYNTHETIC_CSV_B}" "${SYNTHETIC_BIN_A}" "${SYNTHETIC_BIN_B}" "${SYNTHETIC_OUT}"

# CSV columns: timestamp_ns, status_code, latency_ns, bytes_out, bytes_in, error,
# body(base64), attack_name, seq, method, url, headers(base64)
BASE_TS=1700000000000000000

# --- Pod A: odd-millisecond latencies ---
SEQ=0

# Bucket 0 (edge): 10 padding requests
for i in $(seq 1 10); do
    SEQ=$((SEQ + 1))
    TS=$((BASE_TS + i * 1000000))
    echo "${TS},200,5000000,0,13,,,,${SEQ},GET,http://localhost/,"
done > "${SYNTHETIC_CSV_A}"

# Bucket 1 (interior): 50 requests with latencies 1ms, 3ms, 5ms, ..., 99ms
for i in $(seq 1 50); do
    SEQ=$((SEQ + 1))
    TS=$((BASE_TS + 1000000000 + i * 1000000))
    LATENCY=$(( (2 * i - 1) * 1000000 ))  # 1ms, 3ms, 5ms, ..., 99ms
    echo "${TS},200,${LATENCY},0,13,,,,${SEQ},GET,http://localhost/,"
done >> "${SYNTHETIC_CSV_A}"

# Bucket 2 (edge): 10 padding requests
for i in $(seq 1 10); do
    SEQ=$((SEQ + 1))
    TS=$((BASE_TS + 2000000000 + i * 1000000))
    echo "${TS},200,5000000,0,13,,,,${SEQ},GET,http://localhost/,"
done >> "${SYNTHETIC_CSV_A}"

# --- Pod B: even-millisecond latencies ---
SEQ=0

# Bucket 0 (edge): 10 padding requests
for i in $(seq 1 10); do
    SEQ=$((SEQ + 1))
    TS=$((BASE_TS + (i + 10) * 1000000))  # offset slightly so timestamps don't collide
    echo "${TS},200,5000000,0,13,,,,${SEQ},GET,http://localhost/,"
done > "${SYNTHETIC_CSV_B}"

# Bucket 1 (interior): 50 requests with latencies 2ms, 4ms, 6ms, ..., 100ms
for i in $(seq 1 50); do
    SEQ=$((SEQ + 1))
    TS=$((BASE_TS + 1000000000 + (i + 50) * 1000000))  # offset within same second
    LATENCY=$(( 2 * i * 1000000 ))  # 2ms, 4ms, 6ms, ..., 100ms
    echo "${TS},200,${LATENCY},0,13,,,,${SEQ},GET,http://localhost/,"
done >> "${SYNTHETIC_CSV_B}"

# Bucket 2 (edge): 10 padding requests
for i in $(seq 1 10); do
    SEQ=$((SEQ + 1))
    TS=$((BASE_TS + 2000000000 + (i + 10) * 1000000))
    echo "${TS},200,5000000,0,13,,,,${SEQ},GET,http://localhost/,"
done >> "${SYNTHETIC_CSV_B}"

# Convert both CSVs to vegeta binary format
vegeta encode --to gob < "${SYNTHETIC_CSV_A}" > "${SYNTHETIC_BIN_A}"
vegeta encode --to gob < "${SYNTHETIC_CSV_B}" > "${SYNTHETIC_BIN_B}"

if [[ ! -s "${SYNTHETIC_BIN_A}" ]] || [[ ! -s "${SYNTHETIC_BIN_B}" ]]; then
    echo "ERROR: Failed to create synthetic .bin files"
    exit 1
fi

# Merge both pod files — this is the actual multi-pod merge scenario
"${MODULE_DIR}/merge/merge.sh" --output-file "${SYNTHETIC_OUT}" "${SYNTHETIC_BIN_A}" "${SYNTHETIC_BIN_B}"

if [[ ! -s "${SYNTHETIC_OUT}" ]]; then
    echo "ERROR: Merge of synthetic multi-pod data produced no output"
    exit 1
fi

# Should be exactly 3 lines (edge bucket, interior bucket, edge bucket)
SYNTH_LINES=$(wc -l < "${SYNTHETIC_OUT}")
if [[ "${SYNTH_LINES}" -ne 3 ]]; then
    echo "ERROR: Expected 3 lines from synthetic multi-pod data, got ${SYNTH_LINES}"
    cat "${SYNTHETIC_OUT}"
    exit 1
fi

# Validate the interior bucket (line 2) which has the known combined data
SYNTH_LINE=$(sed -n '2p' "${SYNTHETIC_OUT}")

# Verify rps = 100 (50 from pod A + 50 from pod B)
SYNTH_RPS=$(echo "$SYNTH_LINE" | jq -r '.rps')
if [[ "${SYNTH_RPS}" -ne 100 ]]; then
    echo "ERROR: Expected rps=100 (50+50), got ${SYNTH_RPS}"
    echo "$SYNTH_LINE"
    exit 1
fi

# Verify all 100 responses are code 200
SYNTH_200=$(echo "$SYNTH_LINE" | jq -r '.code.hist["200"]')
if [[ "${SYNTH_200}" -ne 100 ]]; then
    echo "ERROR: Expected code 200 count=100, got ${SYNTH_200}"
    echo "$SYNTH_LINE"
    exit 1
fi

# Verify latency percentiles across the combined (interleaved) data
# Combined sorted latencies: 1ms, 2ms, 3ms, ..., 100ms
# p25 = sorted[25] = 25ms = 25000000ns
SYNTH_P25=$(echo "$SYNTH_LINE" | jq -r '.latency.p25')
if [[ "${SYNTH_P25}" -ne 25000000 ]]; then
    echo "ERROR: Expected latency.p25=25000000, got ${SYNTH_P25}"
    echo "$SYNTH_LINE"
    exit 1
fi

# p50 = sorted[50] = 50ms = 50000000ns
SYNTH_P50=$(echo "$SYNTH_LINE" | jq -r '.latency.p50')
if [[ "${SYNTH_P50}" -ne 50000000 ]]; then
    echo "ERROR: Expected latency.p50=50000000, got ${SYNTH_P50}"
    echo "$SYNTH_LINE"
    exit 1
fi

# p99 = sorted[99] = 99ms = 99000000ns
SYNTH_P99=$(echo "$SYNTH_LINE" | jq -r '.latency.p99')
if [[ "${SYNTH_P99}" -ne 99000000 ]]; then
    echo "ERROR: Expected latency.p99=99000000, got ${SYNTH_P99}"
    echo "$SYNTH_LINE"
    exit 1
fi

# Verify bytes_in.sum = 13 * 100 = 1300 (50 from each pod, 13 bytes each)
SYNTH_BYTES_IN=$(echo "$SYNTH_LINE" | jq -r '.bytes_in.sum')
if [[ "${SYNTH_BYTES_IN}" -ne 1300 ]]; then
    echo "ERROR: Expected bytes_in.sum=1300, got ${SYNTH_BYTES_IN}"
    echo "$SYNTH_LINE"
    exit 1
fi

echo "✓ Multi-pod merge latency percentile logic test passed"

echo "17. Testing latency excludes status_code=0 (transport-failure) records..."
# Synthetic CSV with a mix of code-200 successes and code-0 transport failures.
# Vegeta uses status_code=0 for connection refused, EOF, timeout, etc. The
# aggregator must exclude these from latency percentiles (since their "latency"
# is failure-detection time, not service response time) while still counting
# them in rps and code.hist.
#
# Bucket structure (3 second-buckets):
#   bucket 0 (second 0): 5 successes (latencies 10..50ms) + 5 failures (30s timeouts)
#                        → rps=10, successful_count=5, success_rate=0.5
#                        → latency.p99 must reflect only the 200s (≤50ms),
#                          NOT the 30s timeout
#   bucket 1 (second 1): 10 successes only
#                        → rps=10, successful_count=10, success_rate=1.0
#   bucket 2 (second 2): 10 failures only
#                        → rps=10, successful_count=0, success_rate=0.0
#                        → latency must be {0,0,0} without crashing
#
# Both the live path (gawk -f aggregate.awk on unsorted CSV) and the merge path
# (sort | gawk) must produce identical output for this in-order input.

LATFILT_CSV="/tmp/vegeta-test-latfilt.csv"
LATFILT_BIN="/tmp/vegeta-test-latfilt.bin"
LATFILT_LIVE="/tmp/vegeta-test-latfilt-live.json"
LATFILT_MERGE="/tmp/vegeta-test-latfilt-merge.json"
rm -f "${LATFILT_CSV}" "${LATFILT_BIN}" "${LATFILT_LIVE}" "${LATFILT_MERGE}"

BASE_TS=1700000000000000000
TIMEOUT_NS=30000000000  # 30s — the kind of latency a code-0 timeout would carry
SEQ=0

# Bucket 0: 5 × 200 (latencies 10ms, 20ms, 30ms, 40ms, 50ms) + 5 × code-0 (30s)
for i in 1 2 3 4 5; do
    SEQ=$((SEQ + 1))
    TS=$((BASE_TS + i * 1000000))
    LAT=$((i * 10000000))  # 10ms, 20ms, 30ms, 40ms, 50ms
    echo "${TS},200,${LAT},0,13,,,,${SEQ},GET,http://localhost/,"
done > "${LATFILT_CSV}"
for i in 1 2 3 4 5; do
    SEQ=$((SEQ + 1))
    TS=$((BASE_TS + (i + 5) * 1000000))
    echo "${TS},0,${TIMEOUT_NS},0,0,connection refused,,,${SEQ},GET,http://localhost/,"
done >> "${LATFILT_CSV}"

# Bucket 1: 10 × 200 (latencies 5ms each)
for i in $(seq 1 10); do
    SEQ=$((SEQ + 1))
    TS=$((BASE_TS + 1000000000 + i * 1000000))
    echo "${TS},200,5000000,0,13,,,,${SEQ},GET,http://localhost/,"
done >> "${LATFILT_CSV}"

# Bucket 2: 10 × code-0 (30s timeouts)
for i in $(seq 1 10); do
    SEQ=$((SEQ + 1))
    TS=$((BASE_TS + 2000000000 + i * 1000000))
    echo "${TS},0,${TIMEOUT_NS},0,0,connection refused,,,${SEQ},GET,http://localhost/,"
done >> "${LATFILT_CSV}"

# Convert to vegeta binary
vegeta encode --to gob < "${LATFILT_CSV}" > "${LATFILT_BIN}"
if [[ ! -s "${LATFILT_BIN}" ]]; then
    echo "ERROR: Failed to create synthetic .bin file for latency-filter test"
    exit 1
fi

# Round-trip check: decoding the .bin back to CSV must yield the same row count
# as the input CSV. Catches silent gob-encoding loss before downstream assertions.
LATFILT_CSV_LINES=$(wc -l < "${LATFILT_CSV}")
LATFILT_BIN_LINES=$(vegeta encode --to csv "${LATFILT_BIN}" | wc -l)
if [[ "${LATFILT_CSV_LINES}" -ne "${LATFILT_BIN_LINES}" ]]; then
    echo "ERROR: gob round-trip changed row count: input csv=${LATFILT_CSV_LINES}, decoded bin=${LATFILT_BIN_LINES}"
    exit 1
fi

# Live path: vegeta encode --to csv | gawk -f aggregate.awk (no sort)
vegeta encode --to csv "${LATFILT_BIN}" | \
    gawk -f "${MODULE_DIR}/lib/aggregate.awk" > "${LATFILT_LIVE}"

# Merge path: full merge.sh pipeline (sort | gawk)
"${MODULE_DIR}/merge/merge.sh" --output-file "${LATFILT_MERGE}" "${LATFILT_BIN}"

# Both paths must produce identical output for in-order input
if ! diff -q "${LATFILT_LIVE}" "${LATFILT_MERGE}" > /dev/null; then
    echo "ERROR: Live and merge paths produced different output"
    echo "--- live ---"
    cat "${LATFILT_LIVE}"
    echo "--- merge ---"
    cat "${LATFILT_MERGE}"
    exit 1
fi
echo "  ✓ live and merge paths produce identical output"

LATFILT_LINES=$(wc -l < "${LATFILT_MERGE}")
if [[ "${LATFILT_LINES}" -ne 3 ]]; then
    echo "ERROR: Expected 3 buckets, got ${LATFILT_LINES}"
    cat "${LATFILT_MERGE}"
    exit 1
fi

# --- Bucket 0: mixed (5 × 200 + 5 × code-0) ---
B0=$(sed -n '1p' "${LATFILT_MERGE}")
B0_RPS=$(echo "$B0" | jq -r '.rps')
B0_RESP=$(echo "$B0" | jq -r '.responded_count')
B0_SUCC=$(echo "$B0" | jq -r '.successful_count')
B0_200=$(echo "$B0" | jq -r '.code.hist["200"] // 0')
B0_0=$(echo "$B0" | jq -r '.code.hist["0"] // 0')
B0_P25=$(echo "$B0" | jq -r '.latency.p25')
B0_P50=$(echo "$B0" | jq -r '.latency.p50')
B0_P99=$(echo "$B0" | jq -r '.latency.p99')

[[ "${B0_RPS}" -eq 10 ]] || { echo "ERROR bucket0: rps expected 10, got ${B0_RPS} | ${B0}"; exit 1; }
[[ "${B0_RESP}" -eq 5 ]] || { echo "ERROR bucket0: responded_count expected 5, got ${B0_RESP} | ${B0}"; exit 1; }
[[ "${B0_SUCC}" -eq 5 ]] || { echo "ERROR bucket0: successful_count expected 5, got ${B0_SUCC} | ${B0}"; exit 1; }
# response_rate = 5/10 = 0.5 (half of attempts got a response)
echo "$B0" | jq -e '.response_rate == 0.5' > /dev/null || { echo "ERROR bucket0: response_rate expected 0.5 | ${B0}"; exit 1; }
# success_rate = 5/5 = 1 (every response was 2xx)
echo "$B0" | jq -e '.success_rate == 1' > /dev/null || { echo "ERROR bucket0: success_rate expected 1 | ${B0}"; exit 1; }
[[ "${B0_200}" -eq 5 ]] || { echo "ERROR bucket0: code.hist[200] expected 5, got ${B0_200} | ${B0}"; exit 1; }
[[ "${B0_0}" -eq 5 ]] || { echo "ERROR bucket0: code.hist[0] expected 5, got ${B0_0} | ${B0}"; exit 1; }
# Critical: percentiles must be ≤50ms (the worst 200), NOT the 30s timeout
if [[ "${B0_P99}" -gt 50000000 ]]; then
    echo "ERROR bucket0: latency.p99=${B0_P99} > 50ms — code-0 records leaked into percentiles"
    echo "$B0"
    exit 1
fi
# Sanity: percentiles should be drawn from the 5 responded latencies {10,20,30,40,50}ms
# n=5, p25_idx=floor(5*0.25)=1 → 10ms, p50_idx=2 → 20ms, p99_idx=4 → 40ms
[[ "${B0_P25}" -eq 10000000 ]] || { echo "ERROR bucket0: p25 expected 10000000, got ${B0_P25}"; exit 1; }
[[ "${B0_P50}" -eq 20000000 ]] || { echo "ERROR bucket0: p50 expected 20000000, got ${B0_P50}"; exit 1; }
[[ "${B0_P99}" -eq 40000000 ]] || { echo "ERROR bucket0: p99 expected 40000000, got ${B0_P99}"; exit 1; }
echo "  ✓ bucket 0 (mixed): rps=10, resp=5 (rate=0.5), succ=5 (rate=1.0), p99=${B0_P99}ns"

# --- Bucket 1: all successes ---
B1=$(sed -n '2p' "${LATFILT_MERGE}")
B1_RPS=$(echo "$B1" | jq -r '.rps')
B1_RESP=$(echo "$B1" | jq -r '.responded_count')
B1_SUCC=$(echo "$B1" | jq -r '.successful_count')
B1_P50=$(echo "$B1" | jq -r '.latency.p50')

[[ "${B1_RPS}" -eq 10 ]] || { echo "ERROR bucket1: rps expected 10, got ${B1_RPS}"; exit 1; }
[[ "${B1_RESP}" -eq 10 ]] || { echo "ERROR bucket1: responded_count expected 10, got ${B1_RESP}"; exit 1; }
[[ "${B1_SUCC}" -eq 10 ]] || { echo "ERROR bucket1: successful_count expected 10, got ${B1_SUCC}"; exit 1; }
echo "$B1" | jq -e '.response_rate == 1' > /dev/null || { echo "ERROR bucket1: response_rate expected 1 | ${B1}"; exit 1; }
echo "$B1" | jq -e '.success_rate == 1' > /dev/null || { echo "ERROR bucket1: success_rate expected 1 | ${B1}"; exit 1; }
[[ "${B1_P50}" -eq 5000000 ]] || { echo "ERROR bucket1: p50 expected 5000000ns, got ${B1_P50}"; exit 1; }
echo "  ✓ bucket 1 (all success): rps=10, resp=10, succ=10, rate=1.0/1.0, p50=5ms"

# --- Bucket 2: all transport failures ---
B2=$(sed -n '3p' "${LATFILT_MERGE}")
B2_RPS=$(echo "$B2" | jq -r '.rps')
B2_RESP=$(echo "$B2" | jq -r '.responded_count')
B2_SUCC=$(echo "$B2" | jq -r '.successful_count')
B2_0=$(echo "$B2" | jq -r '.code.hist["0"] // 0')
B2_P25=$(echo "$B2" | jq -r '.latency.p25')
B2_P50=$(echo "$B2" | jq -r '.latency.p50')
B2_P99=$(echo "$B2" | jq -r '.latency.p99')

[[ "${B2_RPS}" -eq 10 ]] || { echo "ERROR bucket2: rps expected 10, got ${B2_RPS}"; exit 1; }
[[ "${B2_RESP}" -eq 0 ]] || { echo "ERROR bucket2: responded_count expected 0, got ${B2_RESP}"; exit 1; }
[[ "${B2_SUCC}" -eq 0 ]] || { echo "ERROR bucket2: successful_count expected 0, got ${B2_SUCC}"; exit 1; }
echo "$B2" | jq -e '.response_rate == 0' > /dev/null || { echo "ERROR bucket2: response_rate expected 0 | ${B2}"; exit 1; }
# success_rate is JSON null when responded_count is 0 (ratio is undefined).
echo "$B2" | jq -e '.success_rate == null' > /dev/null || { echo "ERROR bucket2: success_rate expected null | ${B2}"; exit 1; }
[[ "${B2_0}" -eq 10 ]] || { echo "ERROR bucket2: code.hist[0] expected 10, got ${B2_0}"; exit 1; }
# All-failure edge case: latency must be {0,0,0}, JSON shape preserved, no crash
[[ "${B2_P25}" -eq 0 ]] || { echo "ERROR bucket2: p25 expected 0, got ${B2_P25}"; exit 1; }
[[ "${B2_P50}" -eq 0 ]] || { echo "ERROR bucket2: p50 expected 0, got ${B2_P50}"; exit 1; }
[[ "${B2_P99}" -eq 0 ]] || { echo "ERROR bucket2: p99 expected 0, got ${B2_P99}"; exit 1; }
echo "  ✓ bucket 2 (all transport failures): rps=10, resp=0, succ=0, rate=0/0, latency=0/0/0"

# Schema invariants across all lines, plus code.family expectations:
# - all six hundreds keys (0/100/200/300/400/500) always present
# - sum(code.hist) == sum(code.family) == rps (both views describe the same records)
# - successful_count ≤ responded_count ≤ rps (subset chain)
# - success_rate is null exactly when responded_count is 0; otherwise a [0,1] float
while IFS= read -r line; do
    echo "$line" | jq -e '
        (has("rps") and has("responded_count") and has("response_rate")
         and has("successful_count") and has("success_rate")
         and has("code") and has("latency") and has("bytes_in") and has("bytes_out"))
        and (.code | has("hist") and has("family"))
        and (.code.family | has("0") and has("100") and has("200") and has("300") and has("400") and has("500"))
        and (.latency | has("p25") and has("p50") and has("p99"))
        and (([.code.hist[]] | add) == .rps)
        and (([.code.family[]] | add) == .rps)
        and (.response_rate >= 0 and .response_rate <= 1)
        and (
          (.responded_count == 0 and .success_rate == null)
          or (.responded_count > 0 and .success_rate >= 0 and .success_rate <= 1)
        )
        and (.successful_count <= .responded_count)
        and (.responded_count <= .rps)
    ' > /dev/null || { echo "ERROR: schema invariant failed on line: ${line}"; exit 1; }
done < "${LATFILT_MERGE}"
echo "  ✓ schema invariants hold (successful_count ≤ responded_count ≤ rps, sums match, success_rate null iff responded_count=0)"

# Bucket-by-bucket family assertions: 200s land in family["200"], code-0s in family["0"],
# unused families stay at 0.
echo "$B0" | jq -e '.code.family == {"0":5,"100":0,"200":5,"300":0,"400":0,"500":0}' > /dev/null \
    || { echo "ERROR bucket0: code.family mismatch | ${B0}"; exit 1; }
echo "$B1" | jq -e '.code.family == {"0":0,"100":0,"200":10,"300":0,"400":0,"500":0}' > /dev/null \
    || { echo "ERROR bucket1: code.family mismatch | ${B1}"; exit 1; }
echo "$B2" | jq -e '.code.family == {"0":10,"100":0,"200":0,"300":0,"400":0,"500":0}' > /dev/null \
    || { echo "ERROR bucket2: code.family mismatch | ${B2}"; exit 1; }
echo "  ✓ code.family bins exact codes into hundreds families with stable key set"

echo "✓ Latency-filter and success_rate test passed"

echo "18. Testing code.family aggregates distinct codes within each family..."
# Verify the binning logic actually groups distinct exact codes within the same
# hundreds family (e.g. 101 AND 102 both land in family["100"]), and that the
# strict-2xx successful_count rule treats 200 and 204 as successful but 301,
# 400, 500 as not. Test #17's buckets only hit families "0" and "200"; this
# test exercises 1xx/3xx/4xx/5xx with two distinct codes each.
#
# Single second-bucket (no code-0 records — covered in test #17 bucket 2):
#   1xx:  101, 102           → family["100"] = 2
#   2xx:  200, 204           → family["200"] = 2,  successful_count += 2
#   3xx:  301, 302           → family["300"] = 2
#   4xx:  400, 404           → family["400"] = 2
#   5xx:  500, 503           → family["500"] = 2
#   (no 0)                   → family["0"]   = 0
#
# Expected:
#   rps              = 10
#   responded_count  = 10  (all non-0)
#   successful_count =  2  (only 200 and 204 are 2xx)
#   response_rate    =  1
#   success_rate     =  2/10 = 0.2

ALLFAM_CSV="/tmp/vegeta-test-allfam.csv"
ALLFAM_BIN="/tmp/vegeta-test-allfam.bin"
ALLFAM_OUT="/tmp/vegeta-test-allfam.json"
rm -f "${ALLFAM_CSV}" "${ALLFAM_BIN}" "${ALLFAM_OUT}"

ALLFAM_BASE_TS=1700000000000000000
ALLFAM_SEQ=0
# Two distinct codes per non-zero family, all in the same second, all with
# the same 5ms latency so p25/p50/p99 all equal 5ms.
for code in 101 102 200 204 301 302 400 404 500 503; do
    ALLFAM_SEQ=$((ALLFAM_SEQ + 1))
    ts=$((ALLFAM_BASE_TS + ALLFAM_SEQ * 1000000))
    echo "${ts},${code},5000000,0,13,,,,${ALLFAM_SEQ},GET,http://localhost/,"
done > "${ALLFAM_CSV}"

vegeta encode --to gob < "${ALLFAM_CSV}" > "${ALLFAM_BIN}"

# Run both paths (live: csv | gawk; merge: full merge.sh pipeline) and confirm
# they produce identical output for this in-order input. The two paths share
# aggregate.awk so equivalence is structurally guaranteed, but the diff catches
# any future divergence (e.g. different pre-processing steps in merge.sh).
ALLFAM_LIVE="/tmp/vegeta-test-allfam-live.json"
rm -f "${ALLFAM_LIVE}"
vegeta encode --to csv "${ALLFAM_BIN}" | \
    gawk -f "${MODULE_DIR}/lib/aggregate.awk" > "${ALLFAM_LIVE}"
"${MODULE_DIR}/merge/merge.sh" --output-file "${ALLFAM_OUT}" "${ALLFAM_BIN}"

if ! diff -q "${ALLFAM_LIVE}" "${ALLFAM_OUT}" > /dev/null; then
    echo "ERROR: All-family live and merge paths produced different output"
    echo "--- live ---"
    cat "${ALLFAM_LIVE}"
    echo "--- merge ---"
    cat "${ALLFAM_OUT}"
    exit 1
fi
echo "  ✓ live and merge paths produce identical output"

ALLFAM_LINES=$(wc -l < "${ALLFAM_OUT}")
if [[ "${ALLFAM_LINES}" -ne 1 ]]; then
    echo "ERROR: Expected 1 second-bucket, got ${ALLFAM_LINES}"
    cat "${ALLFAM_OUT}"
    exit 1
fi
ALLFAM_LINE=$(cat "${ALLFAM_OUT}")

# code.family must aggregate the two distinct codes per family into one bin each;
# family["0"] is 0 because no code-0 records were sent.
echo "${ALLFAM_LINE}" | jq -e \
    '.code.family == {"0":0,"100":2,"200":2,"300":2,"400":2,"500":2}' > /dev/null \
    || { echo "ERROR: code.family did not aggregate distinct codes | ${ALLFAM_LINE}"; exit 1; }
echo "  ✓ code.family aggregates distinct codes (101+102 → 100:2, 200+204 → 200:2, …)"

# code.hist preserves every distinct exact code with count 1.
echo "${ALLFAM_LINE}" | jq -e \
    '.code.hist == {"101":1,"102":1,"200":1,"204":1,"301":1,"302":1,"400":1,"404":1,"500":1,"503":1}' \
    > /dev/null \
    || { echo "ERROR: code.hist did not preserve all 10 distinct codes | ${ALLFAM_LINE}"; exit 1; }
echo "  ✓ code.hist preserves all 10 distinct exact codes"

# Counts: responded_count = all non-0 = 10; successful_count = strict 2xx (200, 204) = 2.
echo "${ALLFAM_LINE}" | jq -e \
    '.rps == 10 and .responded_count == 10 and .successful_count == 2' > /dev/null \
    || { echo "ERROR: count mismatch | ${ALLFAM_LINE}"; exit 1; }
echo "  ✓ rps=10, responded_count=10, successful_count=2 (200 and 204 only)"

# Rates: response_rate = 10/10 = 1; success_rate = 2/10 = 0.2 (both exact in IEEE754).
echo "${ALLFAM_LINE}" | jq -e '.response_rate == 1 and .success_rate == 0.2' > /dev/null \
    || { echo "ERROR: rate mismatch | ${ALLFAM_LINE}"; exit 1; }
echo "  ✓ response_rate=1.0, success_rate=0.2"

# Sum invariants still hold across both views.
echo "${ALLFAM_LINE}" | jq -e \
    '(([.code.hist[]] | add) == .rps) and (([.code.family[]] | add) == .rps)' > /dev/null \
    || { echo "ERROR: sum invariant failed | ${ALLFAM_LINE}"; exit 1; }
echo "  ✓ sum(code.hist) == sum(code.family) == rps"

echo "✓ All-family bin coverage test passed"

echo ""
echo "All Vegeta module tests passed!"
