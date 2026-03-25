#!/bin/bash

# Script to install ingress-nginx on a Kind cluster.
# This script expects to be run from the root directory of this project.

set -ex

echo "Installing ingress-nginx..."

# Download the Kind-specific ingress-nginx manifest
MANIFEST_URL="https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml"
MANIFEST=$(curl -fsSL "$MANIFEST_URL")

# The Kind manifest gives the controller Deployment a control-plane toleration but
# omits it from the admission Jobs. In single-node Kind clusters this works because
# the control-plane taint is permissive. In multi-node clusters, the control-plane
# gets a full NoSchedule taint and the admission pods have nowhere to schedule.
#
# Insert the control-plane toleration into Jobs by matching the unique pattern of
# nodeSelector followed by restartPolicy (only Jobs have this, not Deployments).
MANIFEST=$(echo "$MANIFEST" | sed '/nodeSelector:/{
  N
  /kubernetes.io\/os: linux/!b
  N
  /restartPolicy: OnFailure/{
    s/restartPolicy: OnFailure/tolerations:\
      - effect: NoSchedule\
        key: node-role.kubernetes.io\/control-plane\
        operator: Exists\
      restartPolicy: OnFailure/
  }
}')

echo "$MANIFEST" | kubectl apply -f -

# Wait for the ingress controller pods to be created
echo "Waiting for ingress-nginx pods to be created..."
sleep 10s

# Wait for the ingress-nginx controller to be ready
echo "Waiting for ingress-nginx controller to be ready..."
kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=90s

# Wait for the admission webhook Service endpoints to be populated.
# This is a necessary (but not always sufficient) condition — kube-proxy
# iptables rules can still take a moment to propagate after this.
# The Helm install in ingress.sh has retry logic to handle the remaining gap.
echo "Waiting for ingress-nginx admission webhook endpoint..."
for i in $(seq 1 30); do
    if kubectl get endpoints ingress-nginx-controller-admission -n ingress-nginx \
        -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
        echo "Admission webhook endpoint is populated."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: Timed out waiting for admission webhook endpoint."
        exit 1
    fi
    echo "  Webhook endpoint not ready yet, retrying in 2s... (attempt $i/30)"
    sleep 2
done

echo "ingress-nginx installed successfully"
