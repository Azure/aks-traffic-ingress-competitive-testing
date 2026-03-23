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
    --rate 5 \
    --duration 2s \
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

# Check that we have successful HTTP 200 responses
STATUS_200_COUNT=$(head -n 1 "${STATEFILE}" | jq -r '.code.hist["200"] // 0' 2>/dev/null || echo "0")
if [[ "${STATUS_200_COUNT}" =~ ^[0-9]+$ ]] && [[ "${STATUS_200_COUNT}" -gt 0 ]]; then
    echo "✓ Found ${STATUS_200_COUNT} successful HTTP 200 responses"
else
    echo "ERROR: Expected HTTP 200 responses but found: ${STATUS_200_COUNT}"
    echo "First line of state file:"
    head -n 1 "${STATEFILE}" 2>/dev/null || echo "State file not found or empty"
    exit 1
fi

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
    --rate 10 \
    --duration 1s \
    --workers 1

echo "✓ Parameter variation test passed"

echo "9. Testing header-only named invocation..."
HEADER_ONLY_OUTPUT=$("${MODULE_DIR}/run/run.sh" \
    --target-url "http://localhost:${TEST_PORT}" \
    --rate 10 \
    --duration 1s \
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
    --rate 10 \
    --duration 1s \
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

echo ""
echo "🎉 All Vegeta module tests passed!"
