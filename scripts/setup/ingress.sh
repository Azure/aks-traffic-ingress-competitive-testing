#!/bin/bash

# Script to deploy the server Helm chart with Ingress traffic object enabled.
# This script expects to be run from the root directory of this project.

set -ex

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Deploys the server Helm chart with Ingress enabled."
    echo ""
    echo "Options:"
    echo "  --ingress-class      The ingress class name (default: nginx)"
    echo "  --replica-count      The number of server replicas (default: 3)"
    echo "  --namespace          The Kubernetes namespace to deploy to (default: server)"
    echo "  --release-name       The Helm release name (default: server)"
    echo "  --chart-path         The path to the Helm chart (default: ./charts/server)"
    echo "  --node-selector      Node selector in key=value form (example: agentpool=userpool)"
    echo "  --tolerations-file   Helm values file containing tolerations YAML"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --ingress-class nginx --replica-count 3"
    echo "  $0 --ingress-class nginx --replica-count 15 --node-selector agentpool=userpool \\"
    echo "    --tolerations-file ./server-tolerations.yaml"
    exit 1
}

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

# Defaults
INGRESS_CLASS="nginx"
REPLICA_COUNT="3"
NAMESPACE="server"
RELEASE_NAME="server"
CHART_PATH="./charts/server"
NODE_SELECTOR=""
TOLERATIONS_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ingress-class)
            INGRESS_CLASS="$2"
            shift 2
            ;;
        --replica-count)
            REPLICA_COUNT="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --release-name)
            RELEASE_NAME="$2"
            shift 2
            ;;
        --chart-path)
            CHART_PATH="$2"
            shift 2
            ;;
        --node-selector)
            NODE_SELECTOR="$2"
            shift 2
            ;;
        --tolerations-file)
            TOLERATIONS_FILE="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            ;;
        *)
            echo "Error: Unknown option: $1"
            show_usage
            ;;
    esac
done

NODE_SELECTOR_KEY=""
NODE_SELECTOR_VALUE=""
if [ -n "$NODE_SELECTOR" ]; then
    if [[ "$NODE_SELECTOR" != *=* ]]; then
        echo "Error: --node-selector must be in <key=value> format"
        exit 1
    fi

    NODE_SELECTOR_KEY="${NODE_SELECTOR%%=*}"
    NODE_SELECTOR_VALUE="${NODE_SELECTOR#*=}"

    if [ -z "$NODE_SELECTOR_KEY" ] || [ -z "$NODE_SELECTOR_VALUE" ]; then
        echo "Error: --node-selector must be in <key=value> format"
        exit 1
    fi
fi

HELM_ARGS=(
    --namespace "$NAMESPACE"
    --create-namespace
    --set ingress.enabled=true
    --set ingress.className="$INGRESS_CLASS"
    --set replicaCount="$REPLICA_COUNT"
)

if [ -n "$NODE_SELECTOR" ]; then
    HELM_ARGS+=(--set-json "nodeSelector={\"$(json_escape "$NODE_SELECTOR_KEY")\":\"$(json_escape "$NODE_SELECTOR_VALUE")\"}")
fi

if [ -n "$TOLERATIONS_FILE" ]; then
    HELM_ARGS+=(--values "$TOLERATIONS_FILE")
fi

echo "Deploying server with Ingress:"
echo "  Ingress Class: $INGRESS_CLASS"
echo "  Replica Count: $REPLICA_COUNT"
echo "  Namespace:        $NAMESPACE"
echo "  Release Name:     $RELEASE_NAME"
echo "  Chart Path:       $CHART_PATH"
echo "  Node Selector:    ${NODE_SELECTOR:-<none>}"
echo "  Tolerations File: ${TOLERATIONS_FILE:-<none>}"

# Retry helm install to handle transient webhook readiness issues.
# The ingress-nginx admission webhook Service can take a few extra seconds
# for kube-proxy iptables rules to propagate even after the controller pod
# is Ready, causing "connection refused" on the first attempt.
HELM_INSTALLED=false
for attempt in $(seq 1 5); do
    if helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" "${HELM_ARGS[@]}"; then
        HELM_INSTALLED=true
        break
    fi
    echo "Helm install attempt $attempt/5 failed, retrying in 5s..."
    sleep 5
done

if [ "$HELM_INSTALLED" = false ]; then
    echo "ERROR: Helm install failed after 5 attempts"
    exit 1
fi

# ---------------------------------------------------------------------------
# Wait for Ingress resource to be created by Helm
# ---------------------------------------------------------------------------

echo "Waiting for Ingress resource to be created..."
for i in {1..30}; do
    if kubectl get ingress "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "Ingress found: $RELEASE_NAME"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: Ingress resource was not created after 60 seconds"
        exit 1
    fi
    echo "Waiting for Ingress resource... (attempt $i/30)"
    sleep 2
done

# ---------------------------------------------------------------------------
# Wait for Ingress to be reachable — LoadBalancer address or NodePort
# ---------------------------------------------------------------------------

# In cloud environments the ingress controller gets a LoadBalancer IP/hostname
# which is written into the Ingress .status by the controller.
# In Kind / bare-metal environments there is no LoadBalancer so the controller
# is reached via a NodePort or host port mapping instead.
# We check for both in the same loop and accept whichever appears first.

echo "Waiting for Ingress to be reachable..."
ingress_ready=""
for i in {1..60}; do
    # Check for a LoadBalancer address on the Ingress resource
    ingress_address=$(kubectl get ingress "$RELEASE_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$ingress_address" ]; then
        echo "✓ Ingress has a LoadBalancer address: $ingress_address"
        ingress_ready="loadbalancer"
        break
    fi

    # Check for a NodePort on the ingress controller service
    ingress_port=$(kubectl get svc -A \
        -l app.kubernetes.io/component=controller,app.kubernetes.io/name=ingress-nginx \
        -o jsonpath='{.items[0].spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "")
    if [ -n "$ingress_port" ]; then
        echo "✓ Ingress controller reachable via NodePort: $ingress_port"
        ingress_ready="nodeport"
        break
    fi

    echo "Waiting for Ingress to be reachable... (attempt $i/60)"
    sleep 5
done

if [ -z "$ingress_ready" ]; then
    echo "No LoadBalancer address or NodePort found — ingress controller may be using host port mappings (e.g. Kind extraPortMappings)"
fi

echo "Ingress configuration:"
kubectl get ingress "$RELEASE_NAME" -n "$NAMESPACE"

# ---------------------------------------------------------------------------
# Wait for server deployment and pods to be ready
# ---------------------------------------------------------------------------

echo "Waiting for server deployment to be ready..."
kubectl rollout status deployment/"$RELEASE_NAME" -n "$NAMESPACE" --timeout=300s

echo "Waiting for all server pods to be ready..."
for i in {1..36}; do
    ready_pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=server \
        -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | grep -o "True" | wc -l)
    total_pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=server \
        --no-headers | wc -l)

    echo "Ready pods: $ready_pods/$total_pods"

    if [ "$ready_pods" -eq "$total_pods" ] && [ "$total_pods" -gt 0 ]; then
        echo "✓ All server pods are ready"
        break
    fi

    if [ "$i" -eq 36 ]; then
        echo "ERROR: Server pods not ready after 6 minutes"
        echo "Pods that are not ready:"
        kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=server \
            -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,READY:.status.conditions[?(@.type=='Ready')].status,REASON:.status.containerStatuses[0].state.waiting.reason"

        not_ready_pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=server \
            -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
            | grep -v "True" | cut -d' ' -f1)

        if [ -n "$not_ready_pods" ]; then
            for pod in $not_ready_pods; do
                echo "--- Pod: $pod ---"
                kubectl describe pod "$pod" -n "$NAMESPACE" | tail -20
                echo "--- End Pod: $pod ---"
            done
        fi

        exit 1
    fi

    echo "Waiting for server pods to be ready... (attempt $i/36)"
    sleep 10
done

echo "Server deployed successfully with Ingress (class: $INGRESS_CLASS)"
