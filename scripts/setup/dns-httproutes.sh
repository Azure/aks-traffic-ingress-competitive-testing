#!/bin/bash

# Script to create N Gateway API HTTPRoute resources, each with a unique hostname,
# all attached to an existing Gateway and routed to the existing backend service.
# Used to test external-dns record reconciliation at scale.
#
# This script expects to be run from the root directory of this project.

set -eo pipefail

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Creates N HTTPRoute resources with hostnames test-{i}.{domain} attached"
    echo "to an existing Gateway. All resources are labeled dns-test=true."
    echo ""
    echo "Options:"
    echo "  --count <N>                   (required) Number of HTTPRoutes to create"
    echo "  --domain <domain>             (required) DNS zone domain (e.g. extdns.telescope.test)"
    echo "  --existing-n <N>              Index offset; objects will be numbered (existing-n+1)..(existing-n+count) (default: 0)"
    echo "  --namespace <ns>              Kubernetes namespace (default: default)"
    echo "  --gateway <name>              Parent Gateway name (default: server)"
    echo "  --gateway-section-name <sec>  Parent Gateway listener section name (default: http)"
    echo "  --service-name <name>         Backend service name (default: server)"
    echo "  --service-port <port>         Backend service port (default: 8080)"
    echo "  -h, --help                    Show this help message"
    exit 1
}

COUNT=""
DOMAIN=""
EXISTING_N="0"
NAMESPACE="default"
GATEWAY="server"
GATEWAY_SECTION_NAME="http"
SERVICE_NAME="server"
SERVICE_PORT="8080"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count)                 COUNT="$2"; shift 2 ;;
        --domain)                DOMAIN="$2"; shift 2 ;;
        --existing-n)            EXISTING_N="$2"; shift 2 ;;
        --namespace)             NAMESPACE="$2"; shift 2 ;;
        --gateway)               GATEWAY="$2"; shift 2 ;;
        --gateway-section-name)  GATEWAY_SECTION_NAME="$2"; shift 2 ;;
        --service-name)          SERVICE_NAME="$2"; shift 2 ;;
        --service-port)          SERVICE_PORT="$2"; shift 2 ;;
        -h|--help)               show_usage ;;
        *)
            echo "Error: Unknown option: $1"
            show_usage
            ;;
    esac
done

if [ -z "$COUNT" ] || [ -z "$DOMAIN" ]; then
    echo "Error: --count and --domain are required"
    show_usage
fi

if ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --count must be a positive integer (>= 1)"
    exit 1
fi

if ! [[ "$EXISTING_N" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "Error: --existing-n must be a non-negative integer (>= 0)"
    exit 1
fi

DNS_LABEL='[a-z0-9]([-a-z0-9]*[a-z0-9])?'
if ! [[ "$DOMAIN" =~ ^${DNS_LABEL}(\.${DNS_LABEL})*$ ]]; then
    echo "Error: --domain '$DOMAIN' is not a valid DNS subdomain (RFC 1123)"
    exit 1
fi

if ! kubectl get gateway.gateway.networking.k8s.io "$GATEWAY" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Error: Gateway '$GATEWAY' not found in namespace '$NAMESPACE'"
    exit 1
fi

if ! kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Error: Service '$SERVICE_NAME' not found in namespace '$NAMESPACE'"
    exit 1
fi

START=$((EXISTING_N + 1))
END=$((EXISTING_N + COUNT))
MANIFEST_FILE="$(mktemp -t dns-httproutes.XXXXXX.yaml)"

echo "Creating $COUNT dns-test HTTPRoutes (indices ${START}..${END}):"
echo "  Domain:        $DOMAIN"
echo "  Namespace:     $NAMESPACE"
echo "  Gateway:       $GATEWAY (section: $GATEWAY_SECTION_NAME)"
echo "  Service:       $SERVICE_NAME:$SERVICE_PORT"
echo "  Manifest file: $MANIFEST_FILE"

: > "$MANIFEST_FILE"
for i in $(seq "$START" "$END"); do
    if [ "$i" -gt "$START" ]; then
        printf '%s\n' '---' >> "$MANIFEST_FILE"
    fi
    cat <<EOF >> "$MANIFEST_FILE"
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: dns-test-${i}
  namespace: ${NAMESPACE}
  labels:
    dns-test: "true"
spec:
  parentRefs:
    - name: ${GATEWAY}
      sectionName: ${GATEWAY_SECTION_NAME}
  hostnames:
    - test-${i}.${DOMAIN}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: ${SERVICE_NAME}
          port: ${SERVICE_PORT}
EOF
done

echo "Applying $COUNT HTTPRoutes from $MANIFEST_FILE in a single bulk request..."
kubectl apply --server-side -f "$MANIFEST_FILE"

echo "Created $COUNT HTTPRoutes with hostnames test-${START}.${DOMAIN} through test-${END}.${DOMAIN}"
