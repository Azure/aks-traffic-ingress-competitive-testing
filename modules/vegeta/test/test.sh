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
    rm -f /tmp/vegeta-test-*.bin /tmp/vegeta-test-*.csv /tmp/vegeta-test-merge-*.json /tmp/vegeta-test-synthetic* || true
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
echo "Running Vegeta and jaggr installation..."
"${MODULE_DIR}/install/install.sh"

# Verify Vegeta is installed
if ! command -v vegeta &> /dev/null; then
    echo "ERROR: Vegeta installation failed - vegeta command not found"
    exit 1
fi

# Verify jaggr is installed
if ! command -v jaggr &> /dev/null; then
    echo "ERROR: jaggr installation failed - jaggr command not found"
    exit 1
fi

echo "✓ Vegeta installation test passed"

echo "2. Testing Vegeta version..."
VEGETA_VERSION=$(vegeta --version)
echo "Vegeta version: ${VEGETA_VERSION}"

JAGGR_VERSION=$(jaggr --version 2>&1 || echo "jaggr version unknown")
echo "jaggr version: ${JAGGR_VERSION}"

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

# Check if state file contains jaggr output format
if ! grep -q "rps" "${STATEFILE}"; then
    echo "ERROR: State file may not contain expected jaggr output format"
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

# Check that each line's rps value is reasonable (roughly near 50, not collapsed or empty)
MIN_REASONABLE_RPS=38   # 0.75x the target rate
MAX_REASONABLE_RPS=63   # 1.25x the target rate
while IFS= read -r line; do
    RPS_VAL=$(echo "$line" | jq -r '.rps // 0')
    if [[ "${RPS_VAL}" -gt "${MAX_REASONABLE_RPS}" ]]; then
        echo "ERROR: RPS value ${RPS_VAL} is unreasonably high (expected near 50, max ${MAX_REASONABLE_RPS})"
        echo "This suggests results were collapsed instead of bucketed per-second"
        echo "Line: ${line}"
        exit 1
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
# merge.sh drops the first and last partial buckets, so expect ~8 lines from a 10s test
MERGE_LINE_COUNT=$(wc -l < "${MERGE_OUTPUT}")
echo "Merge output has ${MERGE_LINE_COUNT} lines (second-buckets) for a 10s test"
if [[ "${MERGE_LINE_COUNT}" -lt 6 ]]; then
    echo "ERROR: Expected at least 6 second-buckets for a 10s test (after edge trim), got ${MERGE_LINE_COUNT}"
    cat "${MERGE_OUTPUT}"
    exit 1
fi

# Verify each line's code histogram sum matches rps, and rps is reasonable
# merge.sh already drops partial edge buckets, so all lines should be complete
MIN_REASONABLE_RPS=38  # 0.75x the target rate
MAX_REASONABLE_RPS=63  # 1.25x the target rate
while IFS= read -r line; do
    RPS_VAL=$(echo "$line" | jq -r '.rps // 0')
    CODE_SUM=$(echo "$line" | jq -r '[.code.hist | to_entries[] | .value] | add // 0')
    if [[ "${CODE_SUM}" -ne "${RPS_VAL}" ]]; then
        echo "ERROR: Merge code histogram sum (${CODE_SUM}) does not match rps (${RPS_VAL})"
        echo "Line: ${line}"
        exit 1
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
# merge.sh drops the first and last partial buckets, so expect ~8 lines from a 10s test
MULTI_MERGE_LINE_COUNT=$(echo "$MULTI_MERGE_OUTPUT" | wc -l)
echo "Multi-file merge output has ${MULTI_MERGE_LINE_COUNT} lines (second-buckets) for a 10s test"
if [[ "${MULTI_MERGE_LINE_COUNT}" -lt 6 ]]; then
    echo "ERROR: Expected at least 6 second-buckets for a 10s test (after edge trim), got ${MULTI_MERGE_LINE_COUNT}"
    echo "$MULTI_MERGE_OUTPUT"
    exit 1
fi

# Verify each line's code histogram sum matches rps, and rps is reasonable
# merge.sh already drops partial edge buckets, so all lines should be complete
MIN_REASONABLE_RPS=75   # 0.75x the combined target rate of ~100
MAX_REASONABLE_RPS=125  # 1.25x the combined target rate of ~100
while IFS= read -r line; do
    RPS_VAL=$(echo "$line" | jq -r '.rps // 0')
    CODE_SUM=$(echo "$line" | jq -r '[.code.hist | to_entries[] | .value] | add // 0')
    if [[ "${CODE_SUM}" -ne "${RPS_VAL}" ]]; then
        echo "ERROR: Multi-merge code histogram sum (${CODE_SUM}) does not match rps (${RPS_VAL})"
        echo "Line: ${line}"
        exit 1
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
# After merge drops the first and last buckets, the interior bucket will contain
# the combined requests from both pods.
#
# Pod A interior bucket: 50 requests with latencies 1ms, 3ms, 5ms, ..., 99ms (odd ms)
# Pod B interior bucket: 50 requests with latencies 2ms, 4ms, 6ms, ..., 100ms (even ms)
# Combined: 100 requests with latencies 1ms, 2ms, 3ms, ..., 100ms
#
# Expected percentiles (same as single-source case):
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

# Bucket 0 (edge — will be dropped): 10 padding requests
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

# Bucket 2 (edge — will be dropped): 10 padding requests
for i in $(seq 1 10); do
    SEQ=$((SEQ + 1))
    TS=$((BASE_TS + 2000000000 + i * 1000000))
    echo "${TS},200,5000000,0,13,,,,${SEQ},GET,http://localhost/,"
done >> "${SYNTHETIC_CSV_A}"

# --- Pod B: even-millisecond latencies ---
SEQ=0

# Bucket 0 (edge — will be dropped): 10 padding requests
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

# Bucket 2 (edge — will be dropped): 10 padding requests
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

# Should be exactly 1 line (the interior bucket; edge buckets are dropped)
SYNTH_LINES=$(wc -l < "${SYNTHETIC_OUT}")
if [[ "${SYNTH_LINES}" -ne 1 ]]; then
    echo "ERROR: Expected 1 line from synthetic multi-pod data (after edge trim), got ${SYNTH_LINES}"
    cat "${SYNTHETIC_OUT}"
    exit 1
fi

SYNTH_LINE=$(cat "${SYNTHETIC_OUT}")

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

echo ""
echo "All Vegeta module tests passed!"
