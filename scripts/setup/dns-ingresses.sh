#!/bin/bash

# Script to create N Kubernetes Ingress resources, each with a unique hostname,
# all routed to the existing backend service. Used to test external-dns record
# reconciliation at scale.
#
# This script expects to be run from the root directory of this project.

set -eo pipefail

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Creates N Ingress resources with hostnames test-{i}.{domain} pointing"
    echo "to the existing backend service. All resources are labeled dns-test=true."
    echo ""
    echo "Options:"
    echo "  --count <N>           (required) Number of ingresses to create"
    echo "  --domain <domain>     (required) DNS zone domain (e.g. extdns.telescope.test)"
    echo "  --existing-n <N>      Index offset; objects will be numbered (existing-n+1)..(existing-n+count) (default: 0)"
    echo "  --namespace <ns>      Kubernetes namespace (default: default)"
    echo "  --ingress-class <cls> Ingress class (default: webapprouting.kubernetes.azure.com)"
    echo "  --service-name <name> Backend service name (default: server)"
    echo "  --service-port <port> Backend service port (default: 8080)"
    echo "  -h, --help            Show this help message"
    exit 1
}

COUNT=""
DOMAIN=""
EXISTING_N="0"
NAMESPACE="default"
INGRESS_CLASS="webapprouting.kubernetes.azure.com"
SERVICE_NAME="server"
SERVICE_PORT="8080"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count)         COUNT="$2"; shift 2 ;;
        --domain)        DOMAIN="$2"; shift 2 ;;
        --existing-n)    EXISTING_N="$2"; shift 2 ;;
        --namespace)     NAMESPACE="$2"; shift 2 ;;
        --ingress-class) INGRESS_CLASS="$2"; shift 2 ;;
        --service-name)  SERVICE_NAME="$2"; shift 2 ;;
        --service-port)  SERVICE_PORT="$2"; shift 2 ;;
        -h|--help)       show_usage ;;
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

# RFC 1123 DNS subdomain: labels of [a-z0-9]([a-z0-9-]*[a-z0-9])?, separated by dots.
DNS_LABEL='[a-z0-9]([-a-z0-9]*[a-z0-9])?'
if ! [[ "$DOMAIN" =~ ^${DNS_LABEL}(\.${DNS_LABEL})*$ ]]; then
    echo "Error: --domain '$DOMAIN' is not a valid DNS subdomain (RFC 1123)"
    exit 1
fi

if ! kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Error: Service '$SERVICE_NAME' not found in namespace '$NAMESPACE'"
    exit 1
fi

START=$((EXISTING_N + 1))
END=$((EXISTING_N + COUNT))
MANIFEST_FILE="$(mktemp -t dns-ingresses.XXXXXX.yaml)"

echo "Creating $COUNT dns-test ingresses (indices ${START}..${END}):"
echo "  Domain:        $DOMAIN"
echo "  Namespace:     $NAMESPACE"
echo "  Ingress Class: $INGRESS_CLASS"
echo "  Service:       $SERVICE_NAME:$SERVICE_PORT"
echo "  Manifest file: $MANIFEST_FILE"

: > "$MANIFEST_FILE"
for i in $(seq "$START" "$END"); do
    if [ "$i" -gt "$START" ]; then
        printf '%s\n' '---' >> "$MANIFEST_FILE"
    fi
    cat <<EOF >> "$MANIFEST_FILE"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dns-test-${i}
  namespace: ${NAMESPACE}
  labels:
    dns-test: "true"
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
    - host: test-${i}.${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${SERVICE_NAME}
                port:
                  number: ${SERVICE_PORT}
EOF
done

echo "Applying $COUNT ingresses from $MANIFEST_FILE in a single bulk request..."
kubectl apply --server-side -f "$MANIFEST_FILE"

echo "Created $COUNT ingresses with hostnames test-${START}.${DOMAIN} through test-${END}.${DOMAIN}"
