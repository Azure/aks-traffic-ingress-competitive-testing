#!/bin/bash

set -e

echo "Testing KIND module..."

# Get the module directory
MODULE_DIR=$( cd "$(dirname "${BASH_SOURCE[0]}")/.." ; pwd -P )
PROJECT_ROOT=$( cd "${MODULE_DIR}/../.." ; pwd -P )
STATEFILE="${MODULE_DIR}/statefile.json"
DEFAULT_CLUSTER_NAME="kind-test-ingress-cluster"
SCHEDULING_CLUSTER_NAME="kind-test-scheduling-cluster"
EXPECTED_HOST_PORT="8080"
SCHEDULING_LABEL_KEY="scheduling"
SCHEDULING_LABEL_VALUE="enabled"
SCHEDULING_TAINT_EFFECT="NoSchedule"

cluster_exists() {
    local cluster_name="$1"
    kind get clusters 2>/dev/null | grep -q "^${cluster_name}$"
}

delete_cluster_if_exists() {
    local cluster_name="$1"
    if cluster_exists "${cluster_name}"; then
        kind delete cluster --name "${cluster_name}" || true
    fi
}

assert_current_context() {
    local cluster_name="$1"
    local expected_context="kind-${cluster_name}"
    local current_context

    current_context=$(kubectl config current-context)
    if [[ "${current_context}" != "${expected_context}" ]]; then
        echo "ERROR: kubectl context not set correctly. Expected: ${expected_context}, Got: ${current_context}"
        exit 1
    fi
}

assert_ready_node_count_at_least() {
    local minimum_count="$1"
    local ready_nodes

    ready_nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c '^True$')
    if [ "${ready_nodes}" -lt "${minimum_count}" ]; then
        echo "ERROR: Expected at least ${minimum_count} Ready node(s), found ${ready_nodes}"
        kubectl get nodes -o wide
        exit 1
    fi
}

assert_statefile() {
    local expected_cluster_name="$1"

    if [[ ! -f "${STATEFILE}" ]]; then
        echo "ERROR: State file was not created at ${STATEFILE}"
        exit 1
    fi

    if [[ "$(jq -r '.cluster_name' "${STATEFILE}")" != "${expected_cluster_name}" ]]; then
        echo "ERROR: State file cluster_name does not match ${expected_cluster_name}"
        cat "${STATEFILE}"
        exit 1
    fi

    if [[ "$(jq -r '.host_port' "${STATEFILE}")" != "${EXPECTED_HOST_PORT}" ]]; then
        echo "ERROR: Expected state file host_port to be ${EXPECTED_HOST_PORT}"
        cat "${STATEFILE}"
        exit 1
    fi
}

assert_output_functions() {
    local expected_cluster_name="$1"

    chmod +x "${MODULE_DIR}/output/output.sh"

    local cluster_name_output
    cluster_name_output=$("${MODULE_DIR}/output/output.sh" cluster_name)
    if [[ "${cluster_name_output}" != "${expected_cluster_name}" ]]; then
        echo "ERROR: Expected cluster_name '${expected_cluster_name}', got '${cluster_name_output}'"
        exit 1
    fi

    local host_port_output
    host_port_output=$("${MODULE_DIR}/output/output.sh" host_port)
    if [[ "${host_port_output}" != "${EXPECTED_HOST_PORT}" ]]; then
        echo "ERROR: Expected host_port '${EXPECTED_HOST_PORT}', got '${host_port_output}'"
        exit 1
    fi
}

assert_scheduling_worker_config() {
    local worker_name="$1"
    local scheduling_label
    local worker_taints

    scheduling_label=$(kubectl get node "${worker_name}" -o jsonpath="{.metadata.labels.${SCHEDULING_LABEL_KEY}}")
    if [[ "${scheduling_label}" != "${SCHEDULING_LABEL_VALUE}" ]]; then
        echo "ERROR: Expected worker ${worker_name} to have label ${SCHEDULING_LABEL_KEY}=${SCHEDULING_LABEL_VALUE}"
        kubectl get node "${worker_name}" --show-labels
        exit 1
    fi

    worker_taints=$(kubectl get node "${worker_name}" -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}')
    if ! printf '%s\n' "${worker_taints}" | grep -q "^${SCHEDULING_LABEL_KEY}=${SCHEDULING_LABEL_VALUE}:${SCHEDULING_TAINT_EFFECT}$"; then
        echo "ERROR: Expected worker ${worker_name} to have taint ${SCHEDULING_LABEL_KEY}=${SCHEDULING_LABEL_VALUE}:${SCHEDULING_TAINT_EFFECT}"
        printf '%s\n' "${worker_taints}"
        exit 1
    fi
}

create_cluster() {
    local cluster_name="$1"
    local topology="$2"

    chmod +x "${MODULE_DIR}/run/run.sh"
    if [[ -n "${topology}" ]]; then
        "${MODULE_DIR}/run/run.sh" "${cluster_name}" --topology "${topology}"
    else
        "${MODULE_DIR}/run/run.sh" "${cluster_name}"
    fi
}

# Cleanup function
cleanup() {
    echo "Cleaning up test clusters..."
    delete_cluster_if_exists "${DEFAULT_CLUSTER_NAME}"
    delete_cluster_if_exists "${SCHEDULING_CLUSTER_NAME}"
    rm -f "${STATEFILE}" || true
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

cd "${PROJECT_ROOT}"

echo "2. Testing default topology cluster creation..."
create_cluster "${DEFAULT_CLUSTER_NAME}" ""

if ! cluster_exists "${DEFAULT_CLUSTER_NAME}"; then
    echo "ERROR: Cluster ${DEFAULT_CLUSTER_NAME} was not created"
    exit 1
fi

echo "✓ Default topology cluster creation test passed"

echo "3. Testing default topology kubectl context..."
assert_current_context "${DEFAULT_CLUSTER_NAME}"
echo "✓ Default topology kubectl context test passed"

echo "4. Testing default topology cluster functionality..."
assert_ready_node_count_at_least 1
echo "✓ Default topology cluster functionality test passed"

echo "5. Testing default topology state file creation..."
assert_statefile "${DEFAULT_CLUSTER_NAME}"
echo "✓ Default topology state file test passed"

echo "6. Testing output functions..."
assert_output_functions "${DEFAULT_CLUSTER_NAME}"
echo "✓ Output functions test passed"

echo "7. Testing default topology cluster recreation..."
create_cluster "${DEFAULT_CLUSTER_NAME}" ""

if ! cluster_exists "${DEFAULT_CLUSTER_NAME}"; then
    echo "ERROR: Cluster ${DEFAULT_CLUSTER_NAME} was not recreated"
    exit 1
fi

assert_ready_node_count_at_least 1
echo "✓ Default topology cluster recreation test passed"

echo "8. Cleaning up default topology cluster before scheduling test..."
delete_cluster_if_exists "${DEFAULT_CLUSTER_NAME}"
echo "✓ Default topology cleanup complete"

echo "9. Testing scheduling-e2e topology cluster creation..."
create_cluster "${SCHEDULING_CLUSTER_NAME}" "scheduling-e2e"

if ! cluster_exists "${SCHEDULING_CLUSTER_NAME}"; then
    echo "ERROR: Cluster ${SCHEDULING_CLUSTER_NAME} was not created"
    exit 1
fi

echo "✓ Scheduling topology cluster creation test passed"

echo "10. Testing scheduling-e2e kubectl context..."
assert_current_context "${SCHEDULING_CLUSTER_NAME}"
echo "✓ Scheduling topology kubectl context test passed"

echo "11. Testing scheduling-e2e node readiness..."
assert_ready_node_count_at_least 2
echo "✓ Scheduling topology node readiness test passed"

echo "12. Testing scheduling-e2e state file contract..."
assert_statefile "${SCHEDULING_CLUSTER_NAME}"
assert_output_functions "${SCHEDULING_CLUSTER_NAME}"
echo "✓ Scheduling topology state file contract test passed"

echo "13. Testing scheduling-e2e worker label and taint..."
assert_scheduling_worker_config "${SCHEDULING_CLUSTER_NAME}-worker"
echo "✓ Scheduling topology worker label and taint test passed"

echo "14. Testing scheduling-e2e cluster recreation..."
create_cluster "${SCHEDULING_CLUSTER_NAME}" "scheduling-e2e"

if ! cluster_exists "${SCHEDULING_CLUSTER_NAME}"; then
    echo "ERROR: Cluster ${SCHEDULING_CLUSTER_NAME} was not recreated"
    exit 1
fi

assert_ready_node_count_at_least 2
assert_statefile "${SCHEDULING_CLUSTER_NAME}"
assert_scheduling_worker_config "${SCHEDULING_CLUSTER_NAME}-worker"
echo "✓ Scheduling topology cluster recreation test passed"

echo "15. Testing error handling..."
if "${MODULE_DIR}/output/output.sh" invalid_function 2>/dev/null; then
    echo "ERROR: output.sh should fail with invalid function name"
    exit 1
fi

echo "✓ Error handling test passed"

echo ""
echo "🎉 All KIND module tests passed!"
