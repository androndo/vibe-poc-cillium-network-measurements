#!/usr/bin/env bash
set -euo pipefail

# Improved script to get network metrics for a specific pod
# This version provides multiple approaches since Cilium global metrics are not pod-specific

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

# Method 1: Show the limitation of global metrics
echo "📊 Method 1: Cilium Global Metrics (LIMITED)"
echo "============================================="
echo "⚠️  WARNING: These are GLOBAL metrics for the entire Cilium agent!"
echo "   They include ALL traffic from ALL pods on this node + system traffic."
echo "   NOT pod-specific metrics!"
echo ""

# Get global metrics
EGRESS_BYTES=$(kubectl exec -n kube-system "$CILIUM_AGENT" -- cilium metrics list | grep 'cilium_forward_bytes_total.*direction="EGRESS"' | awk '{print $NF}' | head -1)
INGRESS_BYTES=$(kubectl exec -n kube-system "$CILIUM_AGENT" -- cilium metrics list | grep 'cilium_forward_bytes_total.*direction="INGRESS"' | awk '{print $NF}' | head -1)

if [[ -n "$EGRESS_BYTES" && -n "$INGRESS_BYTES" ]]; then
    EGRESS_INT=${EGRESS_BYTES%.*}
    INGRESS_INT=${INGRESS_BYTES%.*}
    echo "  Global EGRESS bytes: $(printf "%'d" "$EGRESS_INT")"
    echo "  Global INGRESS bytes: $(printf "%'d" "$INGRESS_INT")"
    echo "  ⚠️  These numbers are for ALL pods on this node!"
fi

echo ""

# Method 2: Use Hubble for pod-specific flows
echo "📊 Method 2: Hubble Flow Analysis (POD-SPECIFIC)"
echo "================================================"

# Check if Hubble is available
if kubectl get pods -n kube-system -l k8s-app=hubble-relay >/dev/null 2>&1; then
    echo "✅ Hubble is available - getting pod-specific flows..."
    
    # Port forward Hubble relay
    kubectl -n kube-system port-forward svc/hubble-relay 4245:80 >/dev/null 2>&1 &
    HUBBLE_PID=$!
    sleep 3
    
    # Get flows for this pod
    if command -v hubble >/dev/null 2>&1; then
        echo "  🔍 Recent flows for $POD_NAME:"
        echo "  Format: Time | Source -> Destination | Verdict | Protocol"
        echo "  ---------------------------------------------------------"
        
        # Get recent flows with better formatting
        hubble observe --server localhost:4245 --pod "$POD_NAME" --follow=false --limit 15 2>/dev/null | while read line; do
            if [[ -n "$line" && "$line" != "EVENTS LOST:"* ]]; then
                echo "  $line"
            fi
        done || echo "  No recent flows found"
        
        echo ""
        echo "  📊 Flow Statistics:"
        
        # Count different types of flows
        TCP_COUNT=$(hubble observe --server localhost:4245 --pod "$POD_NAME" --follow=false --output json 2>/dev/null | jq -r 'select(.flow.l4.TCP != null) | .flow.time' | wc -l)
        UDP_COUNT=$(hubble observe --server localhost:4245 --pod "$POD_NAME" --follow=false --output json 2>/dev/null | jq -r 'select(.flow.l4.UDP != null) | .flow.time' | wc -l)
        FORWARDED_COUNT=$(hubble observe --server localhost:4245 --pod "$POD_NAME" --follow=false --output json 2>/dev/null | jq -r 'select(.flow.verdict == "FORWARDED") | .flow.time' | wc -l)
        DROPPED_COUNT=$(hubble observe --server localhost:4245 --pod "$POD_NAME" --follow=false --output json 2>/dev/null | jq -r 'select(.flow.verdict == "DROPPED") | .flow.time' | wc -l)
        
        echo "    TCP flows: $TCP_COUNT"
        echo "    UDP flows: $UDP_COUNT"
        echo "    Forwarded: $FORWARDED_COUNT"
        echo "    Dropped: $DROPPED_COUNT"
        
        echo ""
        echo "  🌐 External Connections:"
        hubble observe --server localhost:4245 --pod "$POD_NAME" --follow=false --output json 2>/dev/null | jq -r 'select(.flow.destination.pod_name == null and .flow.l4.TCP != null) | "    \(.flow.time) -> \(.flow.IP.destination):\(.flow.l4.TCP.destination_port) (\(.flow.verdict))"' | head -5 || echo "    No external connections found"
        
        echo ""
        echo "  🔗 TCP Connection Flow Analysis:"
        hubble observe --server localhost:4245 --pod "$POD_NAME" --follow=false --output json 2>/dev/null | jq -r 'select(.flow.l4.TCP != null and .flow.verdict == "FORWARDED") | "    \(.flow.time) \(.flow.source.pod_name // "external") -> \(.flow.IP.destination):\(.flow.l4.TCP.destination_port) \(.flow.l4.TCP.flags // "N/A")"' | head -8 || echo "    No TCP flows found"
        
        echo ""
        echo "  📈 Flow Timeline (last 10 flows):"
        hubble observe --server localhost:4245 --pod "$POD_NAME" --follow=false --limit 10 2>/dev/null | while read line; do
            if [[ -n "$line" && "$line" != "EVENTS LOST:"* ]]; then
                # Extract timestamp and flow info
                timestamp=$(echo "$line" | awk '{print $1, $2}')
                flow_info=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}')
                echo "    $timestamp: $flow_info"
            fi
        done || echo "    No flows in timeline"
        
    else
        echo "  ❌ Hubble CLI not found. Install with:"
        echo "     curl -L --remote-name-all https://github.com/cilium/hubble/releases/latest/download/hubble-darwin-amd64.tar.gz"
        echo "     tar xzvf hubble-darwin-amd64.tar.gz && mv hubble ~/bin/"
    fi
    
    # Clean up port forward
    kill $HUBBLE_PID 2>/dev/null || true
else
    echo "❌ Hubble is not available. Enable with:"
    echo "   cilium hubble enable --ui"
fi

echo ""

# Method 3: Container-level metrics
echo "📊 Method 3: Container Network Interface Stats"
echo "=============================================="

# Get container stats from the pod's node
echo "  Container network interface statistics:"
echo "  Format: Interface | RX Bytes | RX Packets | TX Bytes | TX Packets"
echo "  ----------------------------------------------------------------"

# Get and format the network interface stats
kubectl exec -n kube-system "$CILIUM_AGENT" -- sh -c "cat /proc/net/dev" | grep -E "(eth0|lo)" | while read line; do
    # Parse the line: interface rx_bytes rx_packets ... tx_bytes tx_packets
    interface=$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')
    rx_bytes=$(echo "$line" | awk '{print $2}')
    rx_packets=$(echo "$line" | awk '{print $3}')
    tx_bytes=$(echo "$line" | awk '{print $10}')
    tx_packets=$(echo "$line" | awk '{print $11}')
    
    # Format with thousands separators
    rx_bytes_formatted=$(printf "%'d" "$rx_bytes" 2>/dev/null || echo "$rx_bytes")
    rx_packets_formatted=$(printf "%'d" "$rx_packets" 2>/dev/null || echo "$rx_packets")
    tx_bytes_formatted=$(printf "%'d" "$tx_bytes" 2>/dev/null || echo "$tx_bytes")
    tx_packets_formatted=$(printf "%'d" "$tx_packets" 2>/dev/null || echo "$tx_packets")
    
    echo "  $interface | $rx_bytes_formatted bytes | $rx_packets_formatted pkts | $tx_bytes_formatted bytes | $tx_packets_formatted pkts"
done || echo "  Could not retrieve interface stats"

echo ""
echo "  📊 Interface Summary:"
echo "  - lo (loopback): Internal communication within the node"
echo "  - eth0: External network traffic (includes your pod + all other pods)"
echo "  - Note: These are still node-level stats, not pod-specific"
echo ""

# Method 4: Recommendations
echo "💡 Recommendations for Pod-Specific Network Metrics"
echo "=================================================="
echo "1. Use Hubble for per-flow visibility:"
echo "   - Install Hubble CLI and enable Hubble in Cilium"
echo "   - Use: hubble observe --pod <pod-name>"
echo ""
echo "2. Use Prometheus + Grafana with Cilium metrics:"
echo "   - Set up Prometheus to scrape Cilium metrics"
echo "   - Use labels to filter by pod/endpoint"
echo ""
echo "3. Use eBPF tools for detailed packet analysis:"
echo "   - tcpdump, tcpflow, or custom eBPF programs"
echo ""
echo "4. Monitor at the application level:"
echo "   - Add metrics to your application"
echo "   - Use sidecar containers for network monitoring"
echo ""

echo "✅ Analysis complete!"
echo ""
echo "🔍 Summary:"
echo "  - Cilium global metrics show ALL traffic on the node"
echo "  - For pod-specific metrics, use Hubble or application-level monitoring"
echo "  - The high numbers you see include system traffic, other pods, and Cilium internals"
