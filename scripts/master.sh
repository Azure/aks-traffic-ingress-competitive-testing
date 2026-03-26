#!/bin/bash

# Master script that orchestrates the full test pipeline:
#   1. Create a Kind cluster
#   2. Install a traffic controller (nginx or istio)
#   3. Deploy the server via Helm (ingress or gateway)
#   4. Verify optional server pod placement
#   5. Build the ingress URL and wait for it to serve traffic
#   6. Run a scenario
#   7. Delete the Kind cluster
#
# This script expects to be run from the root directory of this project.

set -ex

# ---------------------------------------------------------------------------
# Cleanup trap — ensures resources are freed even if the script fails
# ---------------------------------------------------------------------------

cleanup() {
    echo ""
    echo "============================================================"
    echo "Cleaning up..."
    echo "============================================================"

    # Kill port-forward process if it was started (gateway mode)
    if [ -n "${PORT_FORWARD_PID:-}" ] && kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
        echo "Stopping port-forward (PID $PORT_FORWARD_PID)..."
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
        wait "$PORT_FORWARD_PID" 2>/dev/null || true
        echo "Port-forward stopped."
    fi

    # Delete the Kind cluster if it exists
    if [ -n "${CLUSTER_NAME:-}" ] && kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        echo "Deleting Kind cluster '${CLUSTER_NAME}'..."
        kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
        echo "Kind cluster '${CLUSTER_NAME}' deleted."
    fi
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  --traffic            Traffic object type: 'ingress' or 'gateway'"
    echo "  --scenario           Scenario to run: 'basic-rps' or 'restarting-backend-rps'"
    echo ""
    echo "Optional:"
    echo "  --replica-count      Number of server replicas (default: 3)"
    echo "  --rate               Requests per second (default: 50)"
    echo "  --duration           Test duration (default: 30s)"
    echo "  --workers            Number of vegeta workers (optional; uses vegeta default if omitted)"
    echo "  --output-file        Path for test results JSON (default: auto-generated)"
    echo "  --cluster-name       Kind cluster name (default: kind-test-cluster)"
    echo "  --kind-topology      Kind topology: 'default' or 'scheduling-e2e' (default: default)"
    echo "  --node-selector      Server node selector in key=value form (optional)"
    echo "  --tolerations-file   Helm values file containing server tolerations (optional)"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --traffic ingress --scenario basic-rps"
    echo "  $0 --traffic gateway --scenario restarting-backend-rps --replica-count 5 --duration 90s"
    echo "  $0 --traffic ingress --scenario basic-rps --kind-topology scheduling-e2e \\"
    echo "    --node-selector scheduling=enabled --tolerations-file ./charts/server/ci-scheduling-values.yaml"
    exit 1
}

verify_server_placement() {
    local selector="$1"
    local matching_nodes
    local pod_placements
    local placement_ok=true

    matching_nodes=$(kubectl get nodes -l "$selector" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    if [ -z "$matching_nodes" ]; then
        echo "ERROR: No nodes match selector: $selector"
        echo "Available nodes:"
        kubectl get nodes --show-labels
        exit 1
    fi

    echo "Nodes matching selector '${selector}':"
    while IFS= read -r node_name; do
        if [ -n "$node_name" ]; then
            echo "  $node_name"
        fi
    done <<< "$matching_nodes"

    pod_placements=$(kubectl get pods -n server -l app.kubernetes.io/name=server -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}')
    if [ -z "$pod_placements" ]; then
        echo "ERROR: No server pods found in namespace 'server'"
        kubectl get pods -n server -o wide
        exit 1
    fi

    echo "Server pod placement:"
    while IFS=$'\t' read -r pod_name node_name; do
        [ -z "$pod_name" ] && continue
        echo "  ${pod_name} -> ${node_name:-<unscheduled>}"

        if [ -z "$node_name" ]; then
            placement_ok=false
            continue
        fi

        if ! printf '%s\n' "$matching_nodes" | grep -qx "$node_name"; then
            placement_ok=false
        fi
    done <<< "$pod_placements"

    if [ "$placement_ok" = false ]; then
        echo "ERROR: One or more server pods are not scheduled on nodes matching '${selector}'"
        echo "Current pod placement:"
        kubectl get pods -n server -o wide
        echo "Current nodes:"
        kubectl get nodes --show-labels
        exit 1
    fi

    echo "✓ All server pods are scheduled on nodes matching '${selector}'"
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

TRAFFIC=""
SCENARIO=""
REPLICA_COUNT="3"
RATE="50"
DURATION="30s"
WORKERS=""
OUTPUT_FILE=""
CLUSTER_NAME="kind-test-cluster"
KIND_TOPOLOGY="default"
NODE_SELECTOR=""
TOLERATIONS_FILE=""

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --traffic)
            TRAFFIC="$2"
            shift 2
            ;;
        --scenario)
            SCENARIO="$2"
            shift 2
            ;;
        --replica-count)
            REPLICA_COUNT="$2"
            shift 2
            ;;
        --rate)
            RATE="$2"
            shift 2
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --workers)
            WORKERS="$2"
            shift 2
            ;;
        --output-file)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --kind-topology)
            KIND_TOPOLOGY="$2"
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

# ---------------------------------------------------------------------------
# Validate required arguments
# ---------------------------------------------------------------------------

if [ -z "$TRAFFIC" ]; then
    echo "Error: --traffic is required (ingress or gateway)"
    show_usage
fi

if [ "$TRAFFIC" != "ingress" ] && [ "$TRAFFIC" != "gateway" ]; then
    echo "Error: --traffic must be 'ingress' or 'gateway', got: $TRAFFIC"
    show_usage
fi

if [ -z "$SCENARIO" ]; then
    echo "Error: --scenario is required (basic-rps or restarting-backend-rps)"
    show_usage
fi

if [ "$SCENARIO" != "basic-rps" ] && [ "$SCENARIO" != "restarting-backend-rps" ]; then
    echo "Error: --scenario must be 'basic-rps' or 'restarting-backend-rps', got: $SCENARIO"
    show_usage
fi

if [ "$KIND_TOPOLOGY" != "default" ] && [ "$KIND_TOPOLOGY" != "scheduling-e2e" ]; then
    echo "Error: --kind-topology must be 'default' or 'scheduling-e2e', got: $KIND_TOPOLOGY"
    show_usage
fi

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

# Map scenario name to script path
case "$SCENARIO" in
    basic-rps)
        SCENARIO_SCRIPT="./scripts/scenarios/basic_rps.sh"
        ;;
    restarting-backend-rps)
        SCENARIO_SCRIPT="./scripts/scenarios/restarting_backend_rps.sh"
        ;;
esac

# Auto-generate output file if not specified
if [ -z "$OUTPUT_FILE" ]; then
    OUTPUT_FILE="./results/${TRAFFIC}_${SCENARIO}.json"
fi

echo "============================================================"
echo "Master test configuration:"
echo "  Traffic:          $TRAFFIC"
echo "  Scenario:         $SCENARIO"
echo "  Replica Count:    $REPLICA_COUNT"
echo "  Rate:             $RATE"
echo "  Duration:         $DURATION"
echo "  Workers:          ${WORKERS:-"(vegeta default)"}"
echo "  Output File:      $OUTPUT_FILE"
echo "  Cluster Name:     $CLUSTER_NAME"
echo "  Kind Topology:    $KIND_TOPOLOGY"
echo "  Node Selector:    ${NODE_SELECTOR:-<none>}"
echo "  Tolerations File: ${TOLERATIONS_FILE:-<none>}"
echo "============================================================"

# ---------------------------------------------------------------------------
# Step 1: Create Kind cluster
# ---------------------------------------------------------------------------

echo ""
echo "============================================================"
echo "Step 1: Creating Kind cluster"
echo "============================================================"

chmod +x ./modules/kind/install/install.sh
./modules/kind/install/install.sh

chmod +x ./modules/kind/run/run.sh
./modules/kind/run/run.sh "$CLUSTER_NAME" --topology "$KIND_TOPOLOGY"

# ---------------------------------------------------------------------------
# Step 2: Install traffic controller
# ---------------------------------------------------------------------------

echo ""
echo "============================================================"
echo "Step 2: Installing traffic controller"
echo "============================================================"

if [ "$TRAFFIC" = "ingress" ]; then
    chmod +x ./scripts/install/nginx.sh
    ./scripts/install/nginx.sh
else
    chmod +x ./scripts/install/istio.sh
    ./scripts/install/istio.sh
fi

# ---------------------------------------------------------------------------
# Step 3: Deploy server via Helm
# ---------------------------------------------------------------------------

echo ""
echo "============================================================"
echo "Step 3: Deploying server"
echo "============================================================"

SETUP_ARGS=(--replica-count "$REPLICA_COUNT")

if [ -n "$NODE_SELECTOR" ]; then
    SETUP_ARGS+=(--node-selector "$NODE_SELECTOR")
fi

if [ -n "$TOLERATIONS_FILE" ]; then
    SETUP_ARGS+=(--tolerations-file "$TOLERATIONS_FILE")
fi

if [ "$TRAFFIC" = "ingress" ]; then
    chmod +x ./scripts/setup/ingress.sh
    ./scripts/setup/ingress.sh \
        --ingress-class nginx \
        "${SETUP_ARGS[@]}"
else
    chmod +x ./scripts/setup/gateway.sh
    ./scripts/setup/gateway.sh \
        --gateway-class istio \
        "${SETUP_ARGS[@]}"
fi

# ---------------------------------------------------------------------------
# Step 4: Verify optional server placement
# ---------------------------------------------------------------------------

echo ""
echo "============================================================"
echo "Step 4: Verifying server placement"
echo "============================================================"

if [ -n "$NODE_SELECTOR" ]; then
    verify_server_placement "$NODE_SELECTOR"
else
    echo "Skipping placement verification because no --node-selector was provided"
fi

# ---------------------------------------------------------------------------
# Step 5: Determine ingress URL and wait for it to serve traffic
# ---------------------------------------------------------------------------

echo ""
echo "============================================================"
echo "Step 5: Determining ingress URL and waiting for readiness"
echo "============================================================"

# Read the host port from the Kind state file
HOST_PORT=$(chmod +x ./modules/kind/output/output.sh && ./modules/kind/output/output.sh host_port)

if [ "$TRAFFIC" = "ingress" ]; then
    # nginx uses Kind's extraPortMappings: hostPort -> containerPort 80
    INGRESS_URL="http://localhost:${HOST_PORT}"
else
    # Istio Gateway — In Kind, NodePorts are not accessible from localhost
    # (only extraPortMappings ports are). We use kubectl port-forward to make
    # the gateway service reachable on a local port.
    GATEWAY_LISTENER_PORT=$(kubectl get gateway server -n server \
        -o jsonpath='{.spec.listeners[?(@.name=="http")].port}' 2>/dev/null || echo "8080")

    LOCAL_PORT=8888
    echo "Starting port-forward to server-istio service (port $GATEWAY_LISTENER_PORT -> localhost:$LOCAL_PORT)..."
    kubectl port-forward svc/server-istio -n server "${LOCAL_PORT}:${GATEWAY_LISTENER_PORT}" &
    PORT_FORWARD_PID=$!
    sleep 2

    # Verify port-forward is running
    if ! kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
        echo "ERROR: port-forward failed to start"
        exit 1
    fi

    INGRESS_URL="http://localhost:${LOCAL_PORT}"
fi

echo "Ingress URL: $INGRESS_URL"

echo "Probing $INGRESS_URL until we get an HTTP 200 response..."
READY=false
for i in $(seq 1 60); do
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$INGRESS_URL" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo "✓ Ingress is ready — received HTTP 200 on attempt $i"
        READY=true
        break
    fi
    echo "  Attempt $i/60: HTTP $HTTP_CODE — retrying in 2s..."
    sleep 2
done

if [ "$READY" = false ]; then
    echo "ERROR: Ingress did not return HTTP 200 after 120 seconds"
    echo "Last HTTP status code: $HTTP_CODE"
    echo "Debugging info:"
    kubectl get pods -A
    kubectl get ingress -A || true
    kubectl get gateway -A || true
    curl -v "$INGRESS_URL" 2>&1 || true
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 6: Run scenario
# ---------------------------------------------------------------------------

echo ""
echo "============================================================"
echo "Step 6: Running scenario: $SCENARIO"
echo "============================================================"

chmod +x "$SCENARIO_SCRIPT"
SCENARIO_ARGS=(
    --ingress-url "$INGRESS_URL"
    --rate "$RATE"
    --duration "$DURATION"
    --output-file "$OUTPUT_FILE"
)

if [ -n "$WORKERS" ]; then
    SCENARIO_ARGS+=(--workers "$WORKERS")
fi

"$SCENARIO_SCRIPT" "${SCENARIO_ARGS[@]}"

# ---------------------------------------------------------------------------
# Done — cleanup is handled by the EXIT trap
# ---------------------------------------------------------------------------

echo ""
echo "============================================================"
echo "Test complete!"
echo "  Results: $OUTPUT_FILE"
echo "============================================================"
