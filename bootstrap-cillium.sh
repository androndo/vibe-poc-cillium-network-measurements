#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="cilium"
KIND_CONFIG="kind-cilium.yaml"

echo "🚀 Создаём kind кластер $CLUSTER_NAME с отключённым CNI и kube-proxy..."

cat <<EOF > $KIND_CONFIG
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true   # отключаем kindnet
  kubeProxyMode: "none"     # убираем kube-proxy
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30007   # пробросим порт для Hubble UI
    hostPort: 30007
    protocol: TCP
- role: worker
- role: worker
EOF

kind delete cluster --name $CLUSTER_NAME || true
kind create cluster --name $CLUSTER_NAME --config $KIND_CONFIG

echo "✅ kind кластер создан"

echo "📦 Устанавливаем Cilium..."
cilium install \
  --version v1.16.1 \
  --set kubeProxyReplacement=strict \
  --set k8sServiceHost=${CLUSTER_NAME}-control-plane \
  --set k8sServicePort=6443

echo "⏳ Ждём, пока Cilium поднимется..."
cilium status --wait

echo "✨ Включаем Hubble с UI..."
cilium hubble enable --ui

echo "⏳ Ждём, пока Hubble поднимется..."
kubectl rollout status -n kube-system deploy/hubble-relay --timeout=120s
kubectl rollout status -n kube-system deploy/hubble-ui --timeout=120s

echo "🌐 Настраиваем port-forward для Hubble UI..."
kubectl -n kube-system port-forward svc/hubble-ui 12000:80 >/dev/null 2>&1 &

sleep 3
echo "🎉 Готово! Hubble UI доступен тут: http://localhost:12000"
echo "Для CLI-наблюдения можно использовать: hubble observe"
