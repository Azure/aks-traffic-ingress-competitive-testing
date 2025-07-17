#!/bin/bash

# Script to create and manage KIND clusters
# https://kind.sigs.k8s.io/

set -e

filepath=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
statefile="${filepath}/../statefile.json"

# https://github.com/kubernetes-sigs/gateway-api/releases
latest_gateway_version="v1.3.0"

host_port="8080"
container_port="30080"

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
  - containerPort: ${container_port}
    hostPort: ${host_port}
    protocol: TCP
EOF
}

function install_ingress_nginx() {
    local cluster_name="$1"
    echo "Installing ingress-nginx on KIND cluster: ${cluster_name}..."
    
    # Check if cluster exists
    if ! kind get clusters | grep -q "^${cluster_name}$"; then
        echo "Cluster ${cluster_name} does not exist. Cannot install ingress-nginx."
        return 1
    fi

    # Apply the ingress-nginx manifest
    kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml --context "kind-${cluster_name}"
    
    # Wait for ingress-nginx to be ready
    echo "Waiting for ingress-nginx to be ready..."
    sleep 10s
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=90s \
        --context "kind-${cluster_name}"

    echo "ingress-nginx installed and ready on cluster ${cluster_name}!"
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

function install_gateway_crds() {
    # https://github.com/kubernetes-sigs/gateway-api/releases
    kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${latest_gateway_version}/standard-install.yaml
}

function install_istio() {
    local cluster_name="$1"
    echo "Installing minimal Istio on KIND cluster: ${cluster_name}..."
    
    # Add Istio Helm repository
    helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    
    # Install Istio base
    helm install istio-base istio/base \
        -n istio-system \
        --create-namespace \
        --kube-context "kind-${cluster_name}" \
        --wait
    
    # Install minimal Istiod
    helm install istiod istio/istiod \
        -n istio-system \
        --set pilot.env.EXTERNAL_ISTIOD=false \
        --set global.proxy.privileged=true \
        --kube-context "kind-${cluster_name}" \
        --wait
    
    # Install Istio Ingress Gateway
    helm install istio-ingressgateway istio/gateway \
        -n istio-ingress \
        --create-namespace \
        --kube-context "kind-${cluster_name}"

    echo "✓ Custom Istio ingress gateway manifests applied!"
    echo "✓ Minimal Istio installation complete!"
}

# If script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Parse command line arguments
    ingress_type="${1:-nginx}"  # Default to nginx if no parameter provided
    cluster_name="${2:-kind-test-ingress-cluster}"  # Default cluster name
    
    # Validate ingress type
    if [[ "$ingress_type" != "nginx" && "$ingress_type" != "istio" ]]; then
        echo "Usage: $0 <ingress_type> [cluster_name]"
        echo "  ingress_type: 'nginx' or 'istio'"
        echo "  cluster_name: optional cluster name (default: kind-test-ingress-cluster)"
        echo ""
        echo "Examples:"
        echo "  $0 nginx"
        echo "  $0 istio"
        echo "  $0 nginx my-cluster"
        exit 1
    fi
    
    echo "Creating KIND cluster with ${ingress_type} ingress..."
    
    # Create cluster and set context
    create_kind_cluster "${cluster_name}"
    set_kubectl_context "${cluster_name}"
    
    # Install the appropriate ingress controller
    if [[ "$ingress_type" == "nginx" ]]; then
        install_ingress_nginx "${cluster_name}"
        ingress_class="nginx"
        ingress_url="http://localhost:${host_port}"
    elif [[ "$ingress_type" == "istio" ]]; then
        install_gateway_crds
        install_istio "${cluster_name}"
        ingress_class="istio"
        # For Istio, we'll use the gateway service external IP/port
        ingress_url="http://localhost:${host_port}"
    fi

    # Save the state
    echo "Saving state to ${statefile}..."
    echo "{\"cluster_name\": \"${cluster_name}\", \"ingress_class\": \"${ingress_class}\", \"ingress_url\": \"${ingress_url}\"}" > "${statefile}"
    
    echo ""
    echo "🎉 KIND cluster '${cluster_name}' created successfully with ${ingress_type} ingress!"
    echo "Cluster: ${cluster_name}"
    echo "Ingress class: ${ingress_class}"
    echo "Ingress URL: ${ingress_url}"
fi