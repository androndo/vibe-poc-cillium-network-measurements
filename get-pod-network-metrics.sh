#!/usr/bin/env bash
set -euo pipefail

# Script to get Cilium network metrics for a specific pod
# Usage: ./get-pod-network-metrics.sh <pod-name> [namespace]

POD_NAME="${1:-}"
NAMESPACE="${2:-default}"

if [[ -z "$POD_NAME" ]]; then
    echo "Usage: $0 <pod-name> [namespace]"
    echo "Example: $0 curl-test"
    echo "Example: $0 curl-test default"
    exit 1
fi

echo "🔍 Getting network metrics for pod: $POD_NAME in namespace: $NAMESPACE"
echo "=================================================="

# Check if pod exists
if ! kubectl get pod "$POD_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "❌ Error: Pod '$POD_NAME' not found in namespace '$NAMESPACE'"
    exit 1
fi

# Get pod details
POD_IP=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.podIP}')
POD_NODE=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')

echo "📋 Pod Details:"
echo "  Name: $POD_NAME"
echo "  Namespace: $NAMESPACE"
echo "  IP: $POD_IP"
echo "  Node: $POD_NODE"
echo ""

# Find the Cilium agent pod on the same node
CILIUM_AGENT=$(kubectl get pods -n kube-system -l k8s-app=cilium -o wide | awk -v node="$POD_NODE" '$7 == node {print $1}' | head -1)

if [[ -z "$CILIUM_AGENT" ]]; then
    echo "❌ Error: Could not find Cilium agent on node '$POD_NODE'"
    echo "Available Cilium agents:"
    kubectl get pods -n kube-system -l k8s-app=cilium -o wide
    exit 1
fi

echo "🔧 Using Cilium agent: $CILIUM_AGENT"
echo ""

# Get endpoint ID for the pod
echo "🔍 Finding endpoint for pod..."
ENDPOINT_ID=$(kubectl exec -n kube-system "$CILIUM_AGENT" -- cilium endpoint list | grep "$POD_IP" | awk '{print $1}' | head -1)

if [[ -z "$ENDPOINT_ID" ]]; then
    echo "❌ Error: Could not find endpoint ID for pod IP '$POD_IP'"
    echo "Available endpoints:"
    kubectl exec -n kube-system "$CILIUM_AGENT" -- cilium endpoint list
    exit 1
fi

echo "✅ Found endpoint ID: $ENDPOINT_ID"
echo ""

# Get network metrics
echo "📊 Network Metrics:"
echo "==================="

# Get forward bytes metrics
echo "📤 Bytes Sent (EGRESS):"
EGRESS_BYTES=$(kubectl exec -n kube-system "$CILIUM_AGENT" -- cilium metrics list | grep 'cilium_forward_bytes_total.*direction="EGRESS"' | awk '{print $NF}' | head -1)
if [[ -n "$EGRESS_BYTES" ]]; then
    echo "  Total EGRESS bytes: $(printf "%'d" "${EGRESS_BYTES%.*}") bytes"
else
    echo "  No EGRESS data available"
fi

echo ""

echo "📥 Bytes Received (INGRESS):"
INGRESS_BYTES=$(kubectl exec -n kube-system "$CILIUM_AGENT" -- cilium metrics list | grep 'cilium_forward_bytes_total.*direction="INGRESS"' | awk '{print $NF}' | head -1)
if [[ -n "$INGRESS_BYTES" ]]; then
    echo "  Total INGRESS bytes: $(printf "%'d" "${INGRESS_BYTES%.*}") bytes"
else
    echo "  No INGRESS data available"
fi

echo ""

# Get packet counts
echo "📦 Packet Counts:"
EGRESS_PACKETS=$(kubectl exec -n kube-system "$CILIUM_AGENT" -- cilium metrics list | grep 'cilium_forward_count_total.*direction="EGRESS"' | awk '{print $NF}' | head -1)
INGRESS_PACKETS=$(kubectl exec -n kube-system "$CILIUM_AGENT" -- cilium metrics list | grep 'cilium_forward_count_total.*direction="INGRESS"' | awk '{print $NF}' | head -1)

if [[ -n "$EGRESS_PACKETS" ]]; then
    echo "  EGRESS packets: $(printf "%'d" "${EGRESS_PACKETS%.*}")"
fi
if [[ -n "$INGRESS_PACKETS" ]]; then
    echo "  INGRESS packets: $(printf "%'d" "${INGRESS_PACKETS%.*}")"
fi

echo ""

# Get drop statistics
echo "🚫 Drop Statistics:"
DROP_BYTES=$(kubectl exec -n kube-system "$CILIUM_AGENT" -- cilium metrics list | grep 'cilium_drop_bytes_total' | awk '{print $NF}' | head -1)
DROP_COUNT=$(kubectl exec -n kube-system "$CILIUM_AGENT" -- cilium metrics list | grep 'cilium_drop_count_total' | awk '{print $NF}' | head -1)

if [[ -n "$DROP_BYTES" && "$DROP_BYTES" != "0.000000" ]]; then
    echo "  Dropped bytes: $(printf "%'d" "${DROP_BYTES%.*}")"
fi
if [[ -n "$DROP_COUNT" && "$DROP_COUNT" != "0.000000" ]]; then
    echo "  Dropped packets: $(printf "%'d" "${DROP_COUNT%.*}")"
fi

if [[ -z "$DROP_BYTES" || "$DROP_BYTES" == "0.000000" ]]; then
    echo "  No dropped traffic"
fi

echo ""

# Summary
echo "📈 Summary:"
echo "==========="
if [[ -n "$EGRESS_BYTES" && -n "$INGRESS_BYTES" ]]; then
    EGRESS_INT=${EGRESS_BYTES%.*}
    INGRESS_INT=${INGRESS_BYTES%.*}
    TOTAL_BYTES=$((EGRESS_INT + INGRESS_INT))
    echo "  Total network activity: $(printf "%'d" "$TOTAL_BYTES") bytes"
    echo "  Data sent: $(printf "%'d" "$EGRESS_INT") bytes"
    echo "  Data received: $(printf "%'d" "$INGRESS_INT") bytes"
    
    # Calculate percentages
    if [[ $TOTAL_BYTES -gt 0 ]]; then
        EGRESS_PERCENT=$((EGRESS_INT * 100 / TOTAL_BYTES))
        INGRESS_PERCENT=$((INGRESS_INT * 100 / TOTAL_BYTES))
        echo "  Send/Receive ratio: ${EGRESS_PERCENT}% / ${INGRESS_PERCENT}%"
    fi
fi

echo ""
echo "✅ Network metrics retrieved successfully!"
