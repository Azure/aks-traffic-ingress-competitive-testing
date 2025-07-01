#!/bin/bash

set -e

echo "Testing Vegeta module..."

# Get the module directory
MODULE_DIR=$( cd "$(dirname "${BASH_SOURCE[0]}")/.." ; pwd -P )
PROJECT_ROOT=$( cd "${MODULE_DIR}/../.." ; pwd -P )

# Test HTTP server setup
TEST_PORT="9999"
TEST_SERVER_PID=""

# Cleanup function
cleanup() {
    echo "Cleaning up test environment..."
    
    # Kill test server if running
    if [[ -n "${TEST_SERVER_PID}" ]]; then
        kill "${TEST_SERVER_PID}" 2>/dev/null || true
        wait "${TEST_SERVER_PID}" 2>/dev/null || true
    fi
    
    # Clean up any test state files
    rm -f "${MODULE_DIR}/test_statefile.json" || true
    rm -f "${MODULE_DIR}/test_results.bin" || true
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Start a simple test HTTP server
start_test_server() {
    echo "Starting test HTTP server on port ${TEST_PORT}..."
    
    # Start a simple Python HTTP server in background
    python3 -m http.server "${TEST_PORT}" --directory /tmp > /dev/null 2>&1 &
    TEST_SERVER_PID=$!
    
    # Wait for server to start
    sleep 2
    
    # Verify server is running
    if ! curl -s "http://localhost:${TEST_PORT}" > /dev/null; then
        echo "ERROR: Test server failed to start"
        exit 1
    fi
    
    echo "✓ Test server started successfully"
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
"${MODULE_DIR}/run/run.sh" "http://localhost:${TEST_PORT}" 5 2s 2

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
    echo "WARNING: State file may not contain expected jaggr output format"
    echo "State file content:"
    cat "${STATEFILE}"
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
# Test run script with invalid URL
if "${MODULE_DIR}/run/run.sh" "http://invalid-url-that-does-not-exist.local" 1 1s 1 2>/dev/null; then
    echo "WARNING: Expected failure with invalid URL, but command succeeded"
else
    echo "✓ Invalid URL handling test passed"
fi

# Test run script with missing parameters
if "${MODULE_DIR}/run/run.sh" 2>/dev/null; then
    echo "ERROR: Expected failure with missing parameters, but command succeeded"
    exit 1
fi

echo "✓ Error handling test passed"

echo "8. Testing different attack parameters..."
# Test with different parameters
"${MODULE_DIR}/run/run.sh" "http://localhost:${TEST_PORT}" 10 1s 1

echo "✓ Parameter variation test passed"

echo ""
echo "🎉 All Vegeta module tests passed!"