#!/bin/bash

# Script to create and manage KIND clusters
# https://kind.sigs.k8s.io/

set -e

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
    cat <<EOF | kind create cluster --name "${cluster_name}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: 8080
    protocol: TCP
  - containerPort: 443
    hostPort: 8443
    protocol: TCP
EOF

    # Install ingress-nginx
    kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml --context "kind-${cluster_name}"

    # Wait for ingress-nginx to be ready
    echo "Waiting for ingress-nginx to be ready..."
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=90s \
        --context "kind-${cluster_name}"

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