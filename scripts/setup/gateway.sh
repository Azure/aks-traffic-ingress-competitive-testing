#!/bin/bash

# Script to deploy the server Helm chart with Gateway API traffic object enabled.
# This script expects to be run from the root directory of this project.

set -ex

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Deploys the server Helm chart with Gateway API enabled."
    echo ""
    echo "Options:"
    echo "  --gateway-class      The gateway class name (default: istio)"
    echo "  --replica-count      The number of server replicas (default: 3)"
    echo "  --namespace          The Kubernetes namespace to deploy to (default: server)"
    echo "  --release-name       The Helm release name (default: server)"
    echo "  --chart-path         The path to the Helm chart (default: ./charts/server)"
    echo "  --node-selector      Node selector in key=value form (example: agentpool=userpool)"
    echo "  --tolerations-file   Helm values file containing tolerations YAML"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --gateway-class istio --replica-count 3"
    echo "  $0 --gateway-class istio --replica-count 15 --node-selector agentpool=userpool \\"
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
GATEWAY_CLASS="istio"
REPLICA_COUNT="3"
NAMESPACE="server"
RELEASE_NAME="server"
CHART_PATH="./charts/server"
NODE_SELECTOR=""
TOLERATIONS_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gateway-class)
            GATEWAY_CLASS="$2"
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
    --set gateway.enabled=true
    --set gateway.className="$GATEWAY_CLASS"
    --set replicaCount="$REPLICA_COUNT"
)

if [ -n "$NODE_SELECTOR" ]; then
    HELM_ARGS+=(--set-json "nodeSelector={\"$(json_escape "$NODE_SELECTOR_KEY")\":\"$(json_escape "$NODE_SELECTOR_VALUE")\"}")
fi

if [ -n "$TOLERATIONS_FILE" ]; then
    HELM_ARGS+=(--values "$TOLERATIONS_FILE")
fi

echo "Deploying server with Gateway API:"
echo "  Gateway Class: $GATEWAY_CLASS"
echo "  Replica Count: $REPLICA_COUNT"
echo "  Namespace:        $NAMESPACE"
echo "  Release Name:     $RELEASE_NAME"
echo "  Chart Path:       $CHART_PATH"
echo "  Node Selector:    ${NODE_SELECTOR:-<none>}"
echo "  Tolerations File: ${TOLERATIONS_FILE:-<none>}"

helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" "${HELM_ARGS[@]}"

# ---------------------------------------------------------------------------
# Wait for Gateway and HTTPRoute resources to be created by Helm
# ---------------------------------------------------------------------------

echo "Waiting for Gateway resource to be created..."
for i in {1..30}; do
    if kubectl get gateway "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "Gateway found: $RELEASE_NAME"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: Gateway resource was not created after 60 seconds"
        exit 1
    fi
    echo "Waiting for Gateway resource... (attempt $i/30)"
    sleep 2
done

echo "Waiting for HTTPRoute resource to be created..."
for i in {1..30}; do
    if kubectl get httproute "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "HTTPRoute found: $RELEASE_NAME"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: HTTPRoute resource was not created after 60 seconds"
        exit 1
    fi
    echo "Waiting for HTTPRoute resource... (attempt $i/30)"
    sleep 2
done

# ---------------------------------------------------------------------------
# Wait for Gateway to be ready
# ---------------------------------------------------------------------------

# In cloud environments the Gateway reaches Programmed=True once a LoadBalancer
# address is assigned. In Kind there is no LoadBalancer so Programmed stays
# False even though the Gateway is fully functional. We check for either:
#   - Programmed=True (cloud / LoadBalancer environments), or
#   - The gateway service exists with a port and the listener is programmed (Kind / bare-metal)
#
# kubectl wait --for=condition=Programmed does not work here because in Kind the
# gateway-level Programmed condition stays False — kubectl wait would block for
# the full timeout before the fallback ever runs.

echo "Waiting for Gateway to be ready..."
gateway_ready=""
for i in {1..360}; do
    # Check if the Gateway is fully programmed (cloud environments)
    gateway_programmed=$(kubectl get gateway "$RELEASE_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
    if [ "$gateway_programmed" = "True" ]; then
        echo "✓ Gateway is programmed"
        gateway_ready="true"
        break
    fi

    # Kind / bare-metal fallback: check listener-level condition + service port.
    # Istio names the auto-created service "{gateway}-istio".
    listener_port=$(kubectl get gateway "$RELEASE_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.spec.listeners[?(@.name=="http")].port}' 2>/dev/null || echo "")
    gateway_svc_port=$(kubectl get svc "${RELEASE_NAME}-istio" -n "$NAMESPACE" \
        -o jsonpath="{.spec.ports[?(@.port==${listener_port:-0})].port}" 2>/dev/null || echo "")
    listener_programmed=$(kubectl get gateway "$RELEASE_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.listeners[0].conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
    if [ -n "$gateway_svc_port" ] && [ "$listener_programmed" = "True" ]; then
        echo "✓ Gateway service ${RELEASE_NAME}-istio has port $gateway_svc_port and listener is programmed"
        gateway_ready="true"
        break
    fi

    if [ "$i" -eq 360 ]; then
        echo "ERROR: Gateway is not ready after 30 minutes"
        kubectl get gateway "$RELEASE_NAME" -n "$NAMESPACE" -o yaml || true
        exit 1
    fi

    echo "Waiting for Gateway to be ready... (attempt $i/360)"
    sleep 5
done

echo "Gateway configuration:"
kubectl get gateway "$RELEASE_NAME" -n "$NAMESPACE"

# ---------------------------------------------------------------------------
# Wait for HTTPRoute to be accepted and resolved
# ---------------------------------------------------------------------------

# HTTPRoute conditions are nested under .status.parents[0].conditions, so
# kubectl wait --for=condition= does not work here.

echo "Waiting for HTTPRoute to be ready..."
for i in {1..360}; do
    httproute_accepted=$(kubectl get httproute "$RELEASE_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
    httproute_resolved=$(kubectl get httproute "$RELEASE_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || echo "")

    if [ "$httproute_accepted" = "True" ] && [ "$httproute_resolved" = "True" ]; then
        echo "✓ HTTPRoute is accepted and refs are resolved"
        break
    fi

    if [ "$i" -eq 360 ]; then
        echo "ERROR: HTTPRoute is not ready after 30 minutes"
        echo "HTTPRoute accepted: $httproute_accepted, resolved: $httproute_resolved"
        kubectl get httproute "$RELEASE_NAME" -n "$NAMESPACE" \
            -o jsonpath='{.status.parents[0].conditions}' | jq . || echo "Could not get HTTPRoute conditions"
        exit 1
    fi

    echo "Waiting for HTTPRoute to be ready... (attempt $i/360)"
    sleep 5
done

echo "HTTPRoute configuration:"
kubectl get httproute "$RELEASE_NAME" -n "$NAMESPACE"

# ---------------------------------------------------------------------------
# Wait for server deployment and pods to be ready
# ---------------------------------------------------------------------------

echo "Waiting for server deployment to be ready..."
kubectl rollout status deployment/"$RELEASE_NAME" -n "$NAMESPACE"

echo "Server deployed successfully with Gateway API (class: $GATEWAY_CLASS)"
