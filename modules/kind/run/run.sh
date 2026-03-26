#!/bin/bash

# Script to create and manage KIND clusters
# https://kind.sigs.k8s.io/

set -e

filepath=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
statefile="${filepath}/../statefile.json"

DEFAULT_HOST_PORT="8080"
DEFAULT_TOPOLOGY="default"
SCHEDULING_LABEL_KEY="scheduling"
SCHEDULING_LABEL_VALUE="enabled"
SCHEDULING_TAINT_EFFECT="NoSchedule"

show_usage() {
    echo "Usage: $0 [CLUSTER_NAME] [--topology default|scheduling-e2e]"
    echo ""
    echo "Options:"
    echo "  --topology  KIND topology to create (default: ${DEFAULT_TOPOLOGY})"
    echo "  -h, --help  Show this help message"
}

function write_statefile() {
    local cluster_name="$1"
    local host_port="$2"
    echo "{\"cluster_name\": \"${cluster_name}\", \"host_port\": \"${host_port}\"}" > "${statefile}"
}

function render_kind_config() {
    local topology="$1"
    local host_port="$2"

    case "$topology" in
        default)
            cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: ${host_port}
    protocol: TCP
EOF
            ;;
        scheduling-e2e)
            cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: ${host_port}
    protocol: TCP
- role: worker
EOF
            ;;
        *)
            echo "Error: Unknown topology '${topology}'. Expected 'default' or 'scheduling-e2e'." >&2
            return 1
            ;;
    esac
}

function wait_for_nodes_ready() {
    local cluster_name="$1"
    echo "Waiting for KIND nodes to become Ready..."
    kubectl --context "kind-${cluster_name}" wait --for=condition=Ready node --all --timeout=300s
}

function configure_scheduling_topology() {
    local cluster_name="$1"
    local worker_name="${cluster_name}-worker"

    echo "Configuring scheduling-e2e worker node: ${worker_name}"
    kubectl --context "kind-${cluster_name}" label node "${worker_name}" "${SCHEDULING_LABEL_KEY}=${SCHEDULING_LABEL_VALUE}" --overwrite
    kubectl --context "kind-${cluster_name}" taint node "${worker_name}" "${SCHEDULING_LABEL_KEY}=${SCHEDULING_LABEL_VALUE}:${SCHEDULING_TAINT_EFFECT}" --overwrite

    echo "Scheduling topology nodes:"
    kubectl --context "kind-${cluster_name}" get nodes -L "${SCHEDULING_LABEL_KEY}"
}

function create_kind_cluster() {
    local cluster_name="$1"
    local topology="${2:-${DEFAULT_TOPOLOGY}}"
    local host_port="${DEFAULT_HOST_PORT}"

    echo "Creating KIND cluster: ${cluster_name} (topology: ${topology})..."

    # Check if cluster already exists and delete it
    if kind get clusters | grep -q "^${cluster_name}$"; then
        echo "Cluster ${cluster_name} already exists. Deleting it..."
        kind delete cluster --name "${cluster_name}"
        echo "Existing cluster deleted."
    fi

    render_kind_config "${topology}" "${host_port}" | kind create cluster --name "${cluster_name}" --config=-

    wait_for_nodes_ready "${cluster_name}"

    if [ "${topology}" = "scheduling-e2e" ]; then
        configure_scheduling_topology "${cluster_name}"
    fi

    write_statefile "${cluster_name}" "${host_port}"
    echo "Cluster ${cluster_name} is ready!"
}

function set_kubectl_context() {
    local cluster_name="$1"
    echo "Setting kubectl context to KIND cluster: ${cluster_name}..."

    # Check if cluster exists
    if ! kind get clusters | grep -q "^${cluster_name}$"; then
        echo "Cluster ${cluster_name} does not exist. Cannot set context."
        return 1
    fi

    # Set kubectl context to the KIND cluster
    kubectl config use-context "kind-${cluster_name}"
    echo "kubectl context set to ${cluster_name}"

    # Verify the current context
    kubectl config current-context
}

# If script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cluster_name="kind-test-ingress-cluster"
    topology="${DEFAULT_TOPOLOGY}"
    cluster_name_set=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --topology)
                topology="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            --*)
                echo "Error: Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [ "${cluster_name_set}" = true ]; then
                    echo "Error: Unexpected argument: $1"
                    show_usage
                    exit 1
                fi
                cluster_name="$1"
                cluster_name_set=true
                shift
                ;;
        esac
    done

    if [ "${topology}" != "default" ] && [ "${topology}" != "scheduling-e2e" ]; then
        echo "Error: --topology must be 'default' or 'scheduling-e2e', got: ${topology}"
        show_usage
        exit 1
    fi

    create_kind_cluster "${cluster_name}" "${topology}"
    set_kubectl_context "${cluster_name}"
fi
