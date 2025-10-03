# Cilium Network Metrics Script

This repository contains a script to get Cilium network metrics for specific pods, showing bytes sent and received.

## Files

- `bootstrap-cillium.sh` - Script to set up a Kind cluster with Cilium CNI
- `get-pod-network-metrics.sh` - Script to get network metrics for a specific pod
- `curl-pod.yaml` - Example pod that makes HTTP requests for testing

## Usage

### Get Network Metrics for a Pod

```bash
# Basic usage
./get-pod-network-metrics.sh <pod-name>

# Specify namespace (default is 'default')
./get-pod-network-metrics.sh <pod-name> <namespace>

# Examples
./get-pod-network-metrics.sh curl-test
./get-pod-network-metrics.sh my-app production
```

### Example Output

```
🔍 Getting network metrics for pod: curl-test in namespace: default
==================================================
📋 Pod Details:
  Name: curl-test
  Namespace: default
  IP: 10.244.2.6
  Node: cilium-worker

🔧 Using Cilium agent: cilium-p427d

🔍 Finding endpoint for pod...
✅ Found endpoint ID: 432

📊 Network Metrics:
===================
📤 Bytes Sent (EGRESS):
  Total EGRESS bytes: 3,236,825 bytes

📥 Bytes Received (INGRESS):
  Total INGRESS bytes: 51,842,063 bytes

📦 Packet Counts:
  EGRESS packets: 14,539
  INGRESS packets: 17,380

🚫 Drop Statistics:
  Dropped bytes: 3,574
  Dropped packets: 47

📈 Summary:
===========
  Total network activity: 55,078,888 bytes
  Data sent: 3,236,825 bytes
  Data received: 51,842,063 bytes
  Send/Receive ratio: 5% / 94%

✅ Network metrics retrieved successfully!
```

## Features

- **Automatic Cilium Agent Detection**: Finds the correct Cilium agent on the same node as the pod
- **Comprehensive Metrics**: Shows bytes sent/received, packet counts, and drop statistics
- **Formatted Output**: Human-readable numbers with thousands separators
- **Error Handling**: Validates pod existence and provides helpful error messages
- **Cross-Namespace Support**: Works with pods in any namespace

## Requirements

- Kubernetes cluster with Cilium CNI
- `kubectl` configured to access the cluster
- Bash shell

## How It Works

1. **Pod Validation**: Checks if the specified pod exists
2. **Node Detection**: Finds which node the pod is running on
3. **Cilium Agent Discovery**: Locates the Cilium agent on the same node
4. **Endpoint Mapping**: Maps the pod IP to a Cilium endpoint ID
5. **Metrics Retrieval**: Queries Cilium metrics for network statistics
6. **Data Presentation**: Formats and displays the results

## Metrics Explained

- **EGRESS**: Data sent by the pod (outbound traffic)
- **INGRESS**: Data received by the pod (inbound traffic)
- **Drop Statistics**: Traffic that was dropped by Cilium (with reasons)
- **Packet Counts**: Number of network packets processed

This script provides a direct way to monitor network activity of specific pods using Cilium's built-in metrics, without requiring additional observability tools like Hubble.
