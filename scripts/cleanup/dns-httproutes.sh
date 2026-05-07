#!/bin/bash

# Script to delete all HTTPRoute resources created by setup/dns-httproutes.
# Matches by label: dns-test=true. Does NOT touch the parent Gateway.
#
# This script expects to be run from the root directory of this project.

set -eo pipefail

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Deletes all dns-test HTTPRoutes (label dns-test=true) in the namespace."
    echo "The parent Gateway is left intact."
    echo ""
    echo "Options:"
    echo "  --namespace <ns>  Kubernetes namespace (default: default)"
    echo "  -h, --help        Show this help message"
    exit 1
}

NAMESPACE="default"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace) NAMESPACE="$2"; shift 2 ;;
        -h|--help)   show_usage ;;
        *)
            echo "Error: Unknown option: $1"
            show_usage
            ;;
    esac
done

LABEL="dns-test=true"

echo "Deleting dns-test HTTPRoutes in namespace $NAMESPACE..."
kubectl delete httproute.gateway.networking.k8s.io -n "$NAMESPACE" -l "$LABEL" --wait=false --ignore-not-found

MANIFEST_FILE="$(pwd)/dns-httproutes.yaml"
if [ -f "$MANIFEST_FILE" ]; then
    echo "Removing local manifest file $MANIFEST_FILE..."
    rm -f "$MANIFEST_FILE"
fi

echo "Delete request submitted (--wait=false). Gateway left intact."
