#!/bin/bash

set -e

echo "Testing KIND module..."

# Get the module directory
MODULE_DIR=$( cd "$(dirname "${BASH_SOURCE[0]}")/.." ; pwd -P )
PROJECT_ROOT=$( cd "${MODULE_DIR}/../.." ; pwd -P )

# Test cluster name
TEST_CLUSTER_NAME="kind-test-ingress-cluster"

# Cleanup function
cleanup() {
    echo "Cleaning up test cluster..."
    if kind get clusters 2>/dev/null | grep -q "^${TEST_CLUSTER_NAME}$"; then
        kind delete cluster --name "${TEST_CLUSTER_NAME}" || true
    fi
    # Clean up any test state files
    rm -f "${MODULE_DIR}/statefile.json" || true
}

# Set trap to cleanup on exit
trap cleanup EXIT

echo "1. Testing KIND installation..."
chmod +x "${MODULE_DIR}/install/install.sh"
"${MODULE_DIR}/install/install.sh"

# Verify KIND is installed
if ! command -v kind &> /dev/null; then
    echo "ERROR: KIND installation failed - kind command not found"
    exit 1
fi

echo "✓ KIND installation test passed"

echo "2. Testing cluster creation..."
chmod +x "${MODULE_DIR}/run/run.sh"

# Test cluster creation from project root (as expected)
cd "${PROJECT_ROOT}"
"${MODULE_DIR}/run/run.sh" "${TEST_CLUSTER_NAME}"

# Verify cluster was created
if ! kind get clusters | grep -q "^${TEST_CLUSTER_NAME}$"; then
    echo "ERROR: Cluster ${TEST_CLUSTER_NAME} was not created"
    exit 1
fi

echo "✓ Cluster creation test passed"

echo "3. Testing kubectl context..."
# Verify kubectl context was set
CURRENT_CONTEXT=$(kubectl config current-context)
if [[ "${CURRENT_CONTEXT}" != "kind-${TEST_CLUSTER_NAME}" ]]; then
    echo "ERROR: kubectl context not set correctly. Expected: kind-${TEST_CLUSTER_NAME}, Got: ${CURRENT_CONTEXT}"
    exit 1
fi

echo "✓ kubectl context test passed"

echo "4. Testing cluster functionality..."
# Test basic cluster functionality
kubectl get nodes --no-headers | grep -q "Ready" || {
    echo "ERROR: Cluster nodes are not ready"
    exit 1
}

# Test ingress-nginx installation
kubectl get pods -n ingress-nginx --no-headers | grep -q "Running" || {
    echo "ERROR: ingress-nginx pods are not running"
    exit 1
}

echo "✓ Cluster functionality test passed"

echo "5. Testing state file creation..."
STATEFILE="${MODULE_DIR}/statefile.json"
if [[ ! -f "${STATEFILE}" ]]; then
    echo "ERROR: State file was not created at ${STATEFILE}"
    exit 1
fi

# Verify state file content
if ! jq -e '.cluster_name' "${STATEFILE}" &>/dev/null; then
    echo "ERROR: State file does not contain cluster_name"
    exit 1
fi

if ! jq -e '.ingress_class' "${STATEFILE}" &>/dev/null; then
    echo "ERROR: State file does not contain ingress_class"
    exit 1
fi

if ! jq -e '.ingress_url' "${STATEFILE}" &>/dev/null; then
    echo "ERROR: State file does not contain ingress_url"
    exit 1
fi

echo "✓ State file creation test passed"

echo "6. Testing output functions..."
chmod +x "${MODULE_DIR}/output/output.sh"

# Test ingress_class output
INGRESS_CLASS=$("${MODULE_DIR}/output/output.sh" ingress_class)
if [[ "${INGRESS_CLASS}" != "nginx" ]]; then
    echo "ERROR: Expected ingress_class 'nginx', got '${INGRESS_CLASS}'"
    exit 1
fi

# Test ingress_url output
INGRESS_URL=$("${MODULE_DIR}/output/output.sh" ingress_url)
if [[ ! "${INGRESS_URL}" =~ ^http://localhost:[0-9]+$ ]]; then
    echo "ERROR: Expected ingress_url to match 'http://localhost:PORT', got '${INGRESS_URL}'"
    exit 1
fi

echo "✓ Output functions test passed"

echo "7. Testing cluster deletion and recreation..."
# Test that the cluster can be recreated (should delete existing one)
"${MODULE_DIR}/run/run.sh" "${TEST_CLUSTER_NAME}"

# Verify cluster still exists and is functional
if ! kind get clusters | grep -q "^${TEST_CLUSTER_NAME}$"; then
    echo "ERROR: Cluster ${TEST_CLUSTER_NAME} was not recreated"
    exit 1
fi

echo "✓ Cluster recreation test passed"

echo "8. Testing error handling..."
# Test invalid function call in output script
if "${MODULE_DIR}/output/output.sh" invalid_function 2>/dev/null; then
    echo "ERROR: output.sh should fail with invalid function name"
    exit 1
fi

echo "✓ Error handling test passed"

echo ""
echo "🎉 All KIND module tests passed!"