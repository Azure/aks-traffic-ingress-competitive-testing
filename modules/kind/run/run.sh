#!/bin/bash

# Script to create and manage KIND clusters
# https://kind.sigs.k8s.io/

set -e

filepath=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
statefile="${filepath}/../statefile.json"

function create_kind_cluster() {
    local cluster_name="$1"
    echo "Creating KIND cluster: ${cluster_name}..."
    
    # Check if cluster already exists and delete it
    if kind get clusters | grep -q "^${cluster_name}$"; then
        echo "Cluster ${cluster_name} already exists. Deleting it..."
        kind delete cluster --name "${cluster_name}"
        echo "Existing cluster deleted."
    fi

    # Create cluster with port mappings for ingress
    local host_port="8080"
    cat <<EOF | kind create cluster --name "${cluster_name}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: ${host_port}
    protocol: TCP
EOF

    # Install ingress-nginx
    kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml --context "kind-${cluster_name}"

    # Wait for ingress-nginx to be ready
    echo "Waiting for ingress-nginx to be ready..."
    # Sleep to allow the ingress controller pods to be created
    sleep 5s
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=90s \
        --context "kind-${cluster_name}"

    echo "Cluster ${cluster_name} is ready!"

    # Save to state file
    echo "{\"cluster_name\": \"${cluster_name}\", \"ingress_class\": \"nginx\", \"ingress_url\": \"http://localhost:${host_port}\"}" > "${statefile}"
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
    kubectl config set-context "kind-${cluster_name}"
    echo "kubectl context set to ${cluster_name}"
    
    # Verify the current context
    kubectl config current-context
}

# If script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Set default cluster name or use first argument if provided
    cluster_name="${1:-kind-test-ingress-cluster}"
    create_kind_cluster "${cluster_name}"
    set_kubectl_context "${cluster_name}"
fi